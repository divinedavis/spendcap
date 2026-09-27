// JWT-gated: end one (or every) bank connection the caller owns — at Plaid
// first (/item/remove), then in our database.
//
// Body: { "item_id": "<plaid_items.id>" }  — Settings → Disconnect
//       { "all": true }                    — Delete Account, before delete_account()
//
// Order per item:
//   1. /item/remove with the stored access token
//   2. status = 'removed'  (tells the 0030 trigger not to queue it again)
//   3. delete the plaid_items row (secrets, accounts, transactions cascade)
//
// If Plaid is unreachable the row is still deleted: the 0030 trigger copies
// the token into plaid_item_removals and plaid_removal_cron retries hourly, so
// a user is never stuck unable to disconnect or delete their account because
// of an outage on Plaid's side.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaidConfigured } from "../_shared/plaid.ts";
import { removeAtPlaid } from "../_shared/item_remove.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// A user has at most a handful of banks; this bounds the Plaid calls one
// request can make.
const MAX_ITEMS = 20;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return new Response("Unauthorized", { status: 401 });

    const body = await req.json().catch(() => ({}));
    const itemId: string | undefined = typeof body?.item_id === "string" ? body.item_id : undefined;
    const all = body?.all === true;
    if (!all && !(itemId && UUID_RE.test(itemId))) return json({ error: "item_id or all required" }, 400);

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // The user_id filter is the only thing between a caller and someone
    // else's bank (the service role bypasses RLS) — it is not optional.
    let query = service.from("plaid_items").select("id, status").eq("user_id", user.id);
    if (!all) query = query.eq("id", itemId!);
    const { data: items, error: itemErr } = await query.limit(MAX_ITEMS);
    if (itemErr) throw new Error(`plaid_items: ${itemErr.message}`);

    let removed = 0, queued = 0, deleted = 0;
    for (const item of items ?? []) {
      let atPlaid = item.status === "demo" || item.status === "removed"; // no live Item behind these
      if (!atPlaid && plaidConfigured()) {
        const { data: secret } = await service
          .from("plaid_item_secrets").select("access_token").eq("item_id", item.id).maybeSingle();
        if (!secret) {
          atPlaid = true; // never finished linking: no token, nothing to remove
        } else {
          const { outcome } = await removeAtPlaid(secret.access_token);
          atPlaid = outcome !== "failed";
        }
      }
      if (atPlaid) {
        await service.from("plaid_items").update({ status: "removed" }).eq("id", item.id).eq("user_id", user.id);
        removed++;
      } else {
        queued++; // the 0030 trigger queues the token on delete; the cron retries
      }
      const { error: delErr } = await service.from("plaid_items").delete().eq("id", item.id).eq("user_id", user.id);
      if (delErr) throw new Error(`delete plaid_items: ${delErr.message}`);
      deleted++;
    }

    return json({ ok: true, deleted, removed, queued });
  } catch (err) {
    return json({ error: String(err) }, 500);
  }
});
