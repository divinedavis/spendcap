// Transaction sync + overspend check, shared by the webhook, cron, and
// exchange functions.
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, toCents } from "./plaid.ts";
import { pushToUser } from "./apns.ts";

interface ItemRow {
  id: string;
  user_id: string;
  plaid_item_id: string;
  sync_cursor: string | null;
}

// Runs Plaid /transactions/sync for one item, upserting into public tables.
export async function syncItem(supabase: SupabaseClient, item: ItemRow): Promise<void> {
  const { data: secret, error: secretErr } = await supabase
    .from("plaid_item_secrets").select("access_token").eq("item_id", item.id).single();
  if (secretErr || !secret) throw new Error(`no access token for item ${item.id}`);

  // Map plaid_account_id -> accounts.id for FK writes.
  const { data: accountRows } = await supabase
    .from("accounts").select("id, plaid_account_id").eq("item_id", item.id);
  const accountIds = new Map((accountRows ?? []).map((a: any) => [a.plaid_account_id, a.id]));

  let cursor = item.sync_cursor ?? undefined;
  let hasMore = true;

  // No cursor means this is the item's first sync, so everything arriving now
  // is history we inherited rather than spending we watched happen. That only
  // matters for rows that are still pending: banks report those with no
  // authorized_date, so Plaid dates them to the day they were seen — i.e. the
  // link date — which would otherwise dump the whole unposted backlog onto the
  // user's cap for that day. Marking them lets day totals skip them until they
  // post with a real date. Captured before the loop, since `cursor` is
  // reassigned on every page.
  const isFirstSync = !item.sync_cursor;
  while (hasMore) {
    const page = await plaid("/transactions/sync", {
      access_token: secret.access_token,
      cursor,
      count: 500,
    });

    const upserts = [...page.added, ...page.modified]
      .filter((t: any) => accountIds.has(t.account_id))
      .map((t: any) => ({
        user_id: item.user_id,
        account_id: accountIds.get(t.account_id),
        plaid_transaction_id: t.transaction_id,
        date: t.date,
        authorized_date: t.authorized_date,
        name: t.name ?? "",
        merchant_name: t.merchant_name,
        category: t.personal_finance_category?.primary ?? null,
        amount_cents: toCents(t.amount),
        pending: t.pending ?? false,
        is_removed: false,
        // Later syncs clear the flag, so a backfilled charge starts counting
        // on its true day the moment it posts.
        is_backfill: isFirstSync,
        updated_at: new Date().toISOString(),
      }));
    if (upserts.length) {
      const { error } = await supabase
        .from("transactions").upsert(upserts, { onConflict: "plaid_transaction_id" });
      if (error) throw new Error(`transactions upsert: ${error.message}`);
    }

    const removedIds = (page.removed ?? []).map((t: any) => t.transaction_id);
    if (removedIds.length) {
      await supabase.from("transactions")
        .update({ is_removed: true, updated_at: new Date().toISOString() })
        .in("plaid_transaction_id", removedIds);
    }

    cursor = page.next_cursor;
    hasMore = page.has_more;
    // Persist the cursor each page so a crash never replays a whole history.
    await supabase.from("plaid_items")
      .update({ sync_cursor: cursor, last_synced_at: new Date().toISOString() })
      .eq("id", item.id);
  }

  // Refresh balances once per run. Without this, current_balance_cents stays
  // whatever it was at link time, and the Months balance widget — which
  // derives every month's start/end balance backwards from the current
  // balance — drifts by every dollar spent since linking. /transactions/sync
  // does carry an `accounts` array, but only for accounts with updates in
  // that page (empty on an idle sync — verified live), so it cannot be the
  // anchor. /accounts/get returns the bank's cached balances: not the billed
  // real-time Balance product, and one call per item per run.
  const accts = await plaid("/accounts/get", { access_token: secret.access_token });
  for (const a of accts.accounts ?? []) {
    const accountId = accountIds.get(a.account_id);
    if (!accountId || a.balances?.current == null) continue;
    await supabase.from("accounts")
      .update({ current_balance_cents: toCents(a.balances.current) })
      .eq("id", accountId);
  }
}

export async function syncAllItems(supabase: SupabaseClient): Promise<{ synced: number; errors: string[] }> {
  const { data: items } = await supabase
    .from("plaid_items")
    .select("id, user_id, plaid_item_id, sync_cursor, last_refresh_requested_at")
    .eq("status", "active");
  const errors: string[] = [];
  let synced = 0;
  for (const item of (items ?? []) as (ItemRow & { last_refresh_requested_at: string | null })[]) {
    try {
      await syncItem(supabase, item);
      synced++;
    } catch (e) {
      errors.push(`${item.plaid_item_id}: ${String(e)}`);
    }
    // A stalled item is not a failed sync — /transactions/sync answers fine,
    // there is just nothing new — so the nudge runs regardless, and its own
    // failure must not mark the sweep red.
    try {
      await nudgeIfStale(supabase, item);
    } catch (e) {
      console.warn(`refresh nudge ${item.plaid_item_id}: ${String(e)}`);
    }
  }
  return { synced, errors };
}

// Plaid's own background refresh can silently stall: on 2026-08-12/13 a
// healthy Wells Fargo item (no error, webhook set) went 35 hours without a
// successful transactions update, and a manual /transactions/refresh brought
// the missing rows in within two minutes. So each cron run asks Plaid — via
// the free /item/get — when it last successfully pulled from the bank, and
// past 24 hours requests an on-demand refresh. The refresh is a billed call,
// hence the second clock: at most one request per item per 24 hours, however
// long the staleness lasts. New data still arrives through the normal
// SYNC_UPDATES_AVAILABLE webhook; this only prompts Plaid to go look.
const STALE_AFTER_MS = 24 * 60 * 60 * 1000;
const RENUDGE_AFTER_MS = 24 * 60 * 60 * 1000;

async function nudgeIfStale(
  supabase: SupabaseClient,
  item: ItemRow & { last_refresh_requested_at: string | null },
): Promise<void> {
  const { data: secret } = await supabase
    .from("plaid_item_secrets").select("access_token").eq("item_id", item.id).single();
  if (!secret) return;

  const info = await plaid("/item/get", { access_token: secret.access_token });
  const lastUpdate = info?.status?.transactions?.last_successful_update;
  if (!lastUpdate || Date.now() - Date.parse(lastUpdate) < STALE_AFTER_MS) return;

  const lastRequest = item.last_refresh_requested_at
    ? Date.parse(item.last_refresh_requested_at)
    : 0;
  if (Date.now() - lastRequest < RENUDGE_AFTER_MS) return;

  await plaid("/transactions/refresh", { access_token: secret.access_token });
  await supabase.from("plaid_items")
    .update({ last_refresh_requested_at: new Date().toISOString() })
    .eq("id", item.id);
  console.log(`requested refresh for stale item ${item.plaid_item_id} (last update ${lastUpdate})`);
}

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

// Compares each user's spend today (their timezone) against their daily cap and
// sends at most one "warn" and one "over" push per user per local day.
export async function checkOverspend(supabase: SupabaseClient): Promise<{ warned: number; over: number }> {
  const { data: rows, error } = await supabase.rpc("overspend_status");
  if (error) throw new Error(`overspend_status: ${error.message}`);

  let warned = 0, over = 0;
  for (const row of rows ?? []) {
    const { user_id, local_date, spent_cents, limit_cents, warn_pct } = row;
    if (spent_cents <= 0) continue;

    let kind: "warn" | "over" | null = null;
    if (spent_cents >= limit_cents) kind = "over";
    else if (spent_cents * 100 >= limit_cents * warn_pct) kind = "warn";
    if (!kind) continue;

    // ignoreDuplicates + select(): returns [] when the alert already exists,
    // which is the per-day dedupe.
    const { data: inserted } = await supabase.from("spend_alerts")
      .upsert(
        { user_id, local_date, kind, spent_cents, limit_cents },
        { onConflict: "user_id,local_date,kind", ignoreDuplicates: true },
      )
      .select();
    if (!inserted?.length) continue;

    const overBy = spent_cents - limit_cents;
    const payload = kind === "over"
      ? {
          title: "Over your daily cap",
          body: `You've spent ${dollars(spent_cents)} today — ${dollars(overBy)} over your ${dollars(limit_cents)} cap.`,
          threadId: "spendcap-alerts",
          extra: { type: "over" },
        }
      : {
          title: "Getting close to your cap",
          body: `You've spent ${dollars(spent_cents)} of your ${dollars(limit_cents)} daily cap.`,
          threadId: "spendcap-alerts",
          extra: { type: "warn" },
        };
    await pushToUser(supabase, user_id, payload);
    if (kind === "over") over++; else warned++;
  }
  return { warned, over };
}
