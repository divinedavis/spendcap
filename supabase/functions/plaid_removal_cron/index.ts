// Hourly (deployed --no-verify-jwt, gated by x-cron-secret): drain
// plaid_item_removals, the queue the 0030 trigger fills whenever a plaid_items
// row is deleted without going through plaid_remove_item first (older builds'
// Disconnect, the auth.users cascade, a Plaid outage mid-disconnect).
//
// Each row is one /item/remove call. Removed or already-gone rows are deleted
// from the queue, which also deletes the last copy of the access token.
// Failures stay queued with the error and are retried next hour; after
// MAX_ATTEMPTS they are left for a human (last_error says why).
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaidConfigured } from "../_shared/plaid.ts";
import { removeAtPlaid } from "../_shared/item_remove.ts";
import { secretEquals } from "../_shared/secret.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
if (!CRON_SECRET) throw new Error("CRON_SECRET env var is required");

const MAX_PER_RUN = 25; // bounds Plaid calls per run (/item/remove is not billed)
const MAX_ATTEMPTS = 48;

serve(async (req) => {
  try {
    if (!secretEquals(req.headers.get("x-cron-secret"), CRON_SECRET)) {
      return new Response("Forbidden", { status: 403 });
    }
    if (!plaidConfigured()) {
      return new Response(JSON.stringify({ error: "plaid_not_configured" }), {
        status: 503, headers: { "Content-Type": "application/json" },
      });
    }
    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: rows, error } = await service
      .from("plaid_item_removals")
      .select("id, access_token, attempts")
      .lt("attempts", MAX_ATTEMPTS)
      .order("queued_at", { ascending: true })
      .limit(MAX_PER_RUN);
    if (error) throw new Error(`plaid_item_removals: ${error.message}`);

    let removed = 0, failed = 0;
    for (const row of rows ?? []) {
      const { outcome, error: why } = await removeAtPlaid(row.access_token);
      if (outcome === "failed") {
        failed++;
        await service.from("plaid_item_removals").update({
          attempts: row.attempts + 1, last_error: why ?? null, last_attempt_at: new Date().toISOString(),
        }).eq("id", row.id);
      } else {
        removed++;
        await service.from("plaid_item_removals").delete().eq("id", row.id);
      }
    }
    return new Response(JSON.stringify({ ok: true, removed, failed }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
