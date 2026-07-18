// JWT-gated: exchanges a Link public_token, stores the item + access token
// (server-side only), mirrors accounts, and runs the initial sync.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, toCents } from "../_shared/plaid.ts";
import { syncItem, checkOverspend } from "../_shared/sync.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return new Response("Unauthorized", { status: 401 });

    const { public_token, institution_name } = await req.json();
    if (!public_token) return new Response("Missing public_token", { status: 400 });

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const exchange = await plaid("/item/public_token/exchange", { public_token });

    const { data: itemRow, error: itemErr } = await service
      .from("plaid_items")
      .upsert(
        {
          user_id: user.id,
          plaid_item_id: exchange.item_id,
          institution_name: institution_name ?? null,
          status: "active",
        },
        { onConflict: "plaid_item_id" },
      )
      .select()
      .single();
    if (itemErr || !itemRow) throw new Error(`plaid_items upsert: ${itemErr?.message}`);

    const { error: secretErr } = await service
      .from("plaid_item_secrets")
      .upsert({ item_id: itemRow.id, access_token: exchange.access_token });
    if (secretErr) throw new Error(`secret upsert: ${secretErr.message}`);

    const accts = await plaid("/accounts/get", { access_token: exchange.access_token });
    const accountRows = (accts.accounts ?? []).map((a: any) => ({
      user_id: user.id,
      item_id: itemRow.id,
      plaid_account_id: a.account_id,
      name: a.name ?? "Account",
      mask: a.mask,
      type: a.type,
      subtype: a.subtype,
      current_balance_cents: a.balances?.current != null ? toCents(a.balances.current) : null,
      iso_currency: a.balances?.iso_currency_code ?? "USD",
    }));
    if (accountRows.length) {
      const { error: acctErr } = await service
        .from("accounts").upsert(accountRows, { onConflict: "plaid_account_id" });
      if (acctErr) throw new Error(`accounts upsert: ${acctErr.message}`);
    }

    await syncItem(service, {
      id: itemRow.id,
      user_id: user.id,
      plaid_item_id: exchange.item_id,
      sync_cursor: itemRow.sync_cursor,
    });
    await checkOverspend(service);

    return new Response(JSON.stringify({ ok: true, accounts: accountRows.length }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
