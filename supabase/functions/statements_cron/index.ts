// Daily statement sweep (deployed --no-verify-jwt, gated by x-cron-secret).
// Lists every active item's statements and downloads whatever is new.
//
// Why daily rather than monthly: statement cycles are the bank's, not the
// calendar's — this account's Wells Fargo statement posts around the 8th, and
// a second bank would post on its own day. A monthly job would have to guess
// that date and would silently miss a cycle whenever the bank moved it.
//
// Why that is still cheap: only /statements/list runs every day. Downloads are
// what Plaid bills per request, and already-fetched statements are skipped, so
// the steady state is one download per account per month.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaidConfigured } from "../_shared/plaid.ts";
import { syncAllStatements } from "../_shared/statements.ts";
import { secretEquals } from "../_shared/secret.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
if (!CRON_SECRET) throw new Error("CRON_SECRET env var is required");

// Deliberately far below the tap's 30. An unattended job should pick up the
// month that just posted, never backfill a year: two accounts × one new cycle
// is 2, and the headroom covers a catch-up after an outage. Bulk backfill
// stays behind the Statements screen's pull-to-refresh, where the per-request
// billing is a decision someone made.
const MAX_DOWNLOADS_PER_RUN = 6;

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
    const result = await syncAllStatements(service, MAX_DOWNLOADS_PER_RUN);

    return new Response(JSON.stringify({ ok: true, ...result }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
