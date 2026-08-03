// Plaid webhook authenticity check.
//
// The webhook endpoint is deployed `--no-verify-jwt` because Plaid cannot send a
// Supabase JWT. That does not mean the request is unauthenticated: Plaid signs
// every webhook with an ES256 JWT in the `Plaid-Verification` header, and that
// signature is what we verify here.
//
// Without this check anyone who learned (or guessed) a `plaid_item_id` could
// POST to the endpoint repeatedly and force a full `syncItem` +
// `checkOverspend` cycle each time — billable Plaid API calls and database work
// driven by an anonymous caller.
//
// The procedure is Plaid's documented one:
//   1. Read the `kid` from the JWT header (alg MUST be ES256 — never trust the
//      token's own algorithm claim beyond this allowlist, or an attacker can
//      downgrade to `none`/HS256 and sign with the public key).
//   2. Fetch that key id from /webhook_verification_key/get and cache it.
//   3. Verify the signature against the returned JWK.
//   4. Reject tokens whose `iat` is more than 5 minutes old (replay window).
//   5. Confirm `request_body_sha256` equals the SHA-256 of the *raw* body bytes,
//      which is what binds the signature to this specific payload.

import { decodeProtectedHeader, importJWK, jwtVerify } from "https://deno.land/x/jose@v4.14.4/index.ts";
import { plaid, plaidConfigured } from "./plaid.ts";

const MAX_AGE_SECONDS = 5 * 60;

// Plaid rotates keys, so cache by key id rather than holding a single key.
const keyCache = new Map<string, CryptoKey>();

async function getVerificationKey(kid: string): Promise<CryptoKey> {
  const cached = keyCache.get(kid);
  if (cached) return cached;

  const { key } = await plaid<{ key: Record<string, unknown> }>(
    "/webhook_verification_key/get",
    { key_id: kid },
  );
  // Plaid returns the JWK with `alg: "ES256"` and `use: "sig"`.
  const imported = await importJWK(key as any, "ES256");
  if (!(imported instanceof CryptoKey)) {
    throw new Error("plaid verification key did not import as a CryptoKey");
  }
  keyCache.set(kid, imported);
  return imported;
}

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export type VerifyResult =
  | { ok: true }
  | { ok: false; reason: string };

/**
 * Verify a Plaid webhook. `rawBody` must be the exact bytes received — hashing a
 * re-serialised object would not match the signed digest.
 */
export async function verifyPlaidWebhook(
  req: Request,
  rawBody: string,
): Promise<VerifyResult> {
  if (!plaidConfigured()) {
    // No credentials means we cannot fetch the verification key, so we cannot
    // establish that this call came from Plaid. Fail closed.
    return { ok: false, reason: "plaid not configured" };
  }

  const token = req.headers.get("plaid-verification");
  if (!token) return { ok: false, reason: "missing Plaid-Verification header" };

  let kid: string | undefined;
  try {
    const header = decodeProtectedHeader(token);
    if (header.alg !== "ES256") {
      return { ok: false, reason: `unexpected alg ${header.alg}` };
    }
    kid = header.kid;
  } catch {
    return { ok: false, reason: "malformed verification token" };
  }
  if (!kid) return { ok: false, reason: "verification token has no kid" };

  let claims: Record<string, unknown>;
  try {
    const key = await getVerificationKey(kid);
    // Pinning algorithms here is what stops an algorithm-confusion downgrade.
    const { payload } = await jwtVerify(token, key, { algorithms: ["ES256"] });
    claims = payload as Record<string, unknown>;
  } catch (err) {
    return { ok: false, reason: `signature check failed: ${String(err)}` };
  }

  const iat = typeof claims.iat === "number" ? claims.iat : 0;
  if (!iat || Math.floor(Date.now() / 1000) - iat > MAX_AGE_SECONDS) {
    return { ok: false, reason: "verification token is stale" };
  }

  const expected = claims.request_body_sha256;
  if (typeof expected !== "string") {
    return { ok: false, reason: "verification token has no body digest" };
  }
  const actual = hex(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(rawBody)),
  );
  if (!timingSafeEqual(actual, expected)) {
    return { ok: false, reason: "body digest mismatch" };
  }

  return { ok: true };
}
