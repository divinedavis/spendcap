// Shared statement ingestion: list a Plaid item's statements, download the ones
// we do not already hold, and store the PDFs in the private 'statements'
// bucket with one metadata row each.
//
// Two callers, deliberately different in scope:
//   plaid_statements_sync  JWT-gated, one user, generous cap — a tap that may
//                          be backfilling a year of history on first run.
//   statements_cron        secret-gated, every user, small cap — a daily sweep
//                          that should only ever pick up what just posted.
//
// Statements are a separate Plaid consent from transactions. Until the user has
// been back through Link in update mode, /statements/list answers
// ADDITIONAL_CONSENT_REQUIRED; that is surfaced verbatim so the app can route
// them into the flow, and treated as a skip (not a failure) by the cron.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, plaidDownload } from "./plaid.ts";

export const BUCKET = "statements";

export interface SyncCounts {
  found: number;
  downloaded: number;
  skipped: number;
}

export interface StatementRef {
  statementId: string;
  accountId: string | null;
  year: number;
  month: number;
  periodStart: string | null;
  periodEnd: string | null;
}

export function isConsentError(err: unknown): boolean {
  return String(err).includes("ADDITIONAL_CONSENT_REQUIRED");
}

// Plaid has shipped more than one shape here across API versions: month/year
// as numbers on some, ISO period bounds on others. Derive whatever is missing
// rather than trusting one shape and writing nulls into a not-null column.
export function normalise(raw: any, accountId: string | null): StatementRef | null {
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

export async function syncItemStatements(
  service: SupabaseClient,
  userId: string,
  item: { id: string },
  budget: { left: number },
): Promise<SyncCounts> {
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
  // they are most likely to want rather than the oldest ones on file. This is
  // what makes the cron's small cap safe — the month that just posted is the
  // first thing it reaches.
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

// Every active item, every user — the cron path. One item's failure must not
// end the sweep, or a single revoked bank would stop statements arriving for
// everyone else. Items still awaiting the statements consent are counted
// separately: that is a normal steady state, not an error to alert on.
export async function syncAllStatements(
  service: SupabaseClient,
  maxDownloads: number,
): Promise<SyncCounts & { items: number; awaitingConsent: number; errors: string[]; capped: boolean }> {
  const { data: items, error } = await service
    .from("plaid_items").select("id, user_id, plaid_item_id").eq("status", "active");
  if (error) throw new Error(`plaid_items: ${error.message}`);

  const budget = { left: maxDownloads };
  let found = 0, downloaded = 0, skipped = 0, awaitingConsent = 0;
  const errors: string[] = [];

  for (const item of items ?? []) {
    try {
      const r = await syncItemStatements(service, item.user_id, { id: item.id }, budget);
      found += r.found; downloaded += r.downloaded; skipped += r.skipped;
    } catch (err) {
      if (isConsentError(err)) awaitingConsent++;
      else errors.push(`${item.plaid_item_id}: ${String(err)}`);
    }
  }

  return {
    items: (items ?? []).length,
    found, downloaded, skipped, awaitingConsent, errors,
    capped: budget.left <= 0,
  };
}
