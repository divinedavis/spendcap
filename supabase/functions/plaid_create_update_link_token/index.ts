// JWT-gated: creates an *update mode* Link token for an item the user already
// has, carrying the extra product consent we want to add.
//
// Statements cannot be bolted onto a live item server-side — Plaid scopes
// consent to what the user approved inside Link. Passing `access_token`
// together with `products` puts Link into the additional-consent flow, which
// re-asks the bank for exactly the new product and hands the same item back.
// Crucially this does NOT mint a new Item, so it does not burn one of the
// Trial plan's 10 permanent Item slots the way a fresh link would.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, plaidConfigured } from "../_shared/plaid.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Plaid caps a statements request at 24 months; we ask for 12.
const STATEMENT_MONTHS = 12;

function isoDate(d: Date): string {
  return d.toISOString().slice(0, 10);
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

    const { item_id } = await req.json().catch(() => ({ item_id: undefined }));

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Scope the lookup to the caller. The access token is read with the service
    // role (plaid_item_secrets has no client policies), so the user_id filter
    // is the only thing standing between a caller and someone else's bank —
    // it is not optional.
    let query = service
      .from("plaid_items")
      .select("id, user_id, institution_name")
      .eq("user_id", user.id);
    if (item_id) query = query.eq("id", item_id);
    const { data: items, error: itemErr } = await query
      .order("created_at", { ascending: true })
      .limit(1);
    if (itemErr) throw new Error(`plaid_items: ${itemErr.message}`);
    if (!items?.length) {
      return new Response(JSON.stringify({ error: "no_linked_item" }), {
        status: 404, headers: { "Content-Type": "application/json" },
      });
    }
    const item = items[0];

    const { data: secret, error: secretErr } = await service
      .from("plaid_item_secrets").select("access_token").eq("item_id", item.id).single();
    if (secretErr || !secret) throw new Error(`no access token for item ${item.id}`);

    const end = new Date();
    const start = new Date(end);
    start.setMonth(start.getMonth() - STATEMENT_MONTHS);

    const redirectUri = Deno.env.get("PLAID_REDIRECT_URI") ?? "";

    const resp = await plaid("/link/token/create", {
      client_name: "Spendcap",
      user: { client_user_id: user.id },
      access_token: secret.access_token,
      products: ["statements"],
      country_codes: ["US"],
      language: "en",
      webhook: `${SUPABASE_URL}/functions/v1/plaid_webhook`,
      statements: { start_date: isoDate(start), end_date: isoDate(end) },
      ...(redirectUri ? { redirect_uri: redirectUri } : {}),
    });

    return new Response(
      JSON.stringify({
        link_token: resp.link_token,
        item_id: item.id,
        institution_name: item.institution_name,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
