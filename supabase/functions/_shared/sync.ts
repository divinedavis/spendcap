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
}

export async function syncAllItems(supabase: SupabaseClient): Promise<{ synced: number; errors: string[] }> {
  const { data: items } = await supabase
    .from("plaid_items").select("id, user_id, plaid_item_id, sync_cursor").eq("status", "active");
  const errors: string[] = [];
  let synced = 0;
  for (const item of (items ?? []) as ItemRow[]) {
    try {
      await syncItem(supabase, item);
      synced++;
    } catch (e) {
      errors.push(`${item.plaid_item_id}: ${String(e)}`);
    }
  }
  return { synced, errors };
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
