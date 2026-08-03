// Plaid webhook receiver (deployed --no-verify-jwt; Plaid can't send a Supabase
// JWT). Authenticity comes instead from Plaid's own ES256 signature in the
// `Plaid-Verification` header — see ../_shared/plaid_verify.ts.
//
// This used to accept any caller on the reasoning that a spoofed call could
// "at worst trigger a redundant sync". That understated it: each accepted call
// costs a full syncItem + checkOverspend against the Plaid API, so an anonymous
// caller who knew an item_id could drive unbounded billable work. Unverified
// requests are now rejected outright.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncItem, checkOverspend } from "../_shared/sync.ts";
import { verifyPlaidWebhook } from "../_shared/plaid_verify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    // Read the body as text first: the signature covers these exact bytes, so
    // it has to be hashed before anything re-serialises it.
    const rawBody = await req.text();

    const verified = await verifyPlaidWebhook(req, rawBody);
    if (!verified.ok) {
      // 401, not 200 — an unverified caller is not Plaid, so there is no
      // webhook to keep healthy by acknowledging.
      console.warn("rejected unverified plaid webhook:", verified.reason);
      return new Response(JSON.stringify({ error: "unverified" }), { status: 401 });
    }

    const hook = JSON.parse(rawBody);
    if (hook.webhook_type !== "TRANSACTIONS") {
      return new Response(JSON.stringify({ ignored: hook.webhook_type }), { status: 200 });
    }

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: item } = await service
      .from("plaid_items")
      .select("id, user_id, plaid_item_id, sync_cursor")
      .eq("plaid_item_id", hook.item_id ?? "")
      .eq("status", "active")
      .maybeSingle();
    if (!item) return new Response(JSON.stringify({ ignored: "unknown item" }), { status: 200 });

    await syncItem(service, item);
    await checkOverspend(service);

    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  } catch (err) {
    // Always 200 so Plaid doesn't disable the webhook; errors land in fn logs.
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 200 });
  }
});
