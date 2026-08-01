// JWT-gated: pulls the user's bank statements from Plaid and stores the PDFs
// in the private 'statements' bucket, one row of metadata per statement.
//
// Runs only after the user has re-consented through Link update mode — until
// then Plaid answers /statements/list with ADDITIONAL_CONSENT_REQUIRED, which
// is surfaced verbatim so the app can send them back through the flow instead
// of showing a generic failure.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, plaidConfigured, plaidDownload } from "../_shared/plaid.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BUCKET = "statements";
// Hard ceiling on downloads per invocation. Plaid bills statements per
// request, and a bank with many accounts × 24 months could otherwise fan out
// into hundreds of paid calls from a single tap. Already-fetched statements
// are skipped, so a second run picks up whatever this one left behind.
const MAX_DOWNLOADS_PER_RUN = 30;

interface StatementRef {
  statementId: string;
  accountId: string | null;
  year: number;
  month: number;
  periodStart: string | null;
  periodEnd: string | null;
}

// Plaid has shipped more than one shape here across API versions: month/year
// as numbers on some, ISO period bounds on others. Derive whatever is missing
// rather than trusting one shape and writing nulls into a not-null column.
function normalise(raw: any, accountId: string | null): StatementRef | null {
  const statementId = raw?.statement_id;
  if (!statementId) return null;

  const periodStart: string | null = raw.period_start ?? null;
  const periodEnd: string | null = raw.period_end ?? null;

  let year = Number(raw.year);
  let month = Number(raw.month);
  if (!Number.isFinite(year) || !Number.isFinite(month)) {
    const basis = periodEnd ?? periodStart;
    if (!basis) return null;
    const d = new Date(`${basis}T00:00:00Z`);
    if (Number.isNaN(d.getTime())) return null;
    year = d.getUTCFullYear();
    month = d.getUTCMonth() + 1;
  }
  if (month < 1 || month > 12) return null;

  return { statementId, accountId, year, month, periodStart, periodEnd };
}

async function syncItemStatements(
  service: SupabaseClient,
  userId: string,
  item: { id: string },
  budget: { left: number },
): Promise<{ found: number; downloaded: number; skipped: number }> {
  const { data: secret, error: secretErr } = await service
    .from("plaid_item_secrets").select("access_token").eq("item_id", item.id).single();
  if (secretErr || !secret) throw new Error(`no access token for item ${item.id}`);

  const list = await plaid("/statements/list", { access_token: secret.access_token });

  const { data: accountRows } = await service
    .from("accounts").select("id, plaid_account_id").eq("item_id", item.id);
  const accountIds = new Map((accountRows ?? []).map((a: any) => [a.plaid_account_id, a.id]));

  const refs: StatementRef[] = [];
  for (const acct of list.accounts ?? []) {
    const localAccountId = accountIds.get(acct.account_id) ?? null;
    for (const raw of acct.statements ?? []) {
      const ref = normalise(raw, localAccountId);
      if (ref) refs.push(ref);
    }
  }

  // Skip anything already downloaded so re-runs are cheap and idempotent.
  // storage_path is null on rows whose download failed, so those retry.
  const { data: existing } = await service
    .from("statements")
    .select("plaid_statement_id, storage_path")
    .eq("user_id", userId);
  const done = new Set(
    (existing ?? []).filter((r: any) => r.storage_path).map((r: any) => r.plaid_statement_id),
  );

  let downloaded = 0;
  let skipped = 0;
  // Newest first: if the cap truncates the run, the user gets the statements
  // they are most likely to want rather than the oldest ones on file.
  refs.sort((a, b) => (b.year - a.year) || (b.month - a.month));

  for (const ref of refs) {
    if (done.has(ref.statementId)) { skipped++; continue; }
    if (budget.left <= 0) { skipped++; continue; }
    budget.left--;

    const path = `${userId}/${ref.statementId}.pdf`;
    let storagePath: string | null = null;
    let byteSize: number | null = null;
    try {
      const pdf = await plaidDownload("/statements/download", {
        access_token: secret.access_token,
        statement_id: ref.statementId,
      });
      const { error: upErr } = await service.storage
        .from(BUCKET)
        .upload(path, pdf, { contentType: "application/pdf", upsert: true });
      if (upErr) throw new Error(`storage upload: ${upErr.message}`);
      storagePath = path;
      byteSize = pdf.byteLength;
      downloaded++;
    } catch (_err) {
      // Record the statement anyway with a null storage_path. A visible row
      // that failed to download beats a silently missing month.
      storagePath = null;
    }

    const { error: rowErr } = await service.from("statements").upsert(
      {
        user_id: userId,
        item_id: item.id,
        account_id: ref.accountId,
        plaid_statement_id: ref.statementId,
        period_start: ref.periodStart,
        period_end: ref.periodEnd,
        year: ref.year,
        month: ref.month,
        storage_path: storagePath,
        byte_size: byteSize,
        fetched_at: storagePath ? new Date().toISOString() : null,
      },
      { onConflict: "plaid_statement_id" },
    );
    if (rowErr) throw new Error(`statements upsert: ${rowErr.message}`);
  }

  return { found: refs.length, downloaded, skipped };
}

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return new Response("Unauthorized", { status: 401 });

    if (!plaidConfigured()) {
      return new Response(JSON.stringify({ error: "plaid_not_configured" }), {
        status: 503, headers: { "Content-Type": "application/json" },
      });
    }

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: items, error: itemErr } = await service
      .from("plaid_items").select("id").eq("user_id", user.id);
    if (itemErr) throw new Error(`plaid_items: ${itemErr.message}`);
    if (!items?.length) {
      return new Response(JSON.stringify({ error: "no_linked_item" }), {
        status: 404, headers: { "Content-Type": "application/json" },
      });
    }

    const budget = { left: MAX_DOWNLOADS_PER_RUN };
    let found = 0, downloaded = 0, skipped = 0;
    for (const item of items) {
      const r = await syncItemStatements(service, user.id, item, budget);
      found += r.found; downloaded += r.downloaded; skipped += r.skipped;
    }

    return new Response(
      JSON.stringify({ ok: true, found, downloaded, skipped, capped: budget.left <= 0 }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    const message = String(err);
    // Surface the consent gate as its own code so the app can route the user
    // back into Link update mode rather than showing a dead end.
    if (message.includes("ADDITIONAL_CONSENT_REQUIRED")) {
      return new Response(
        JSON.stringify({ error: "additional_consent_required" }),
        { status: 409, headers: { "Content-Type": "application/json" } },
      );
    }
    return new Response(JSON.stringify({ error: message }), { status: 500 });
  }
});
