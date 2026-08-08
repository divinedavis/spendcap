// JWT-gated: pulls the signed-in user's bank statements from Plaid and stores
// the PDFs in the private 'statements' bucket, one row of metadata per
// statement. The ingestion itself lives in _shared/statements.ts, shared with
// the daily statements_cron sweep.
//
// Runs only after the user has re-consented through Link update mode — until
// then Plaid answers /statements/list with ADDITIONAL_CONSENT_REQUIRED, which
// is surfaced as its own code so the app can send them back through the flow
// instead of showing a generic failure.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaidConfigured } from "../_shared/plaid.ts";
import { isConsentError, syncItemStatements } from "../_shared/statements.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Hard ceiling on downloads per invocation. Plaid bills statements per
// request, and a bank with many accounts × 24 months could otherwise fan out
// into hundreds of paid calls from a single tap. Already-fetched statements
// are skipped, so a second run picks up whatever this one left behind.
const MAX_DOWNLOADS_PER_RUN = 30;

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
    // Surface the consent gate as its own code so the app can route the user
    // back into Link update mode rather than showing a dead end.
    if (isConsentError(err)) {
      return new Response(
        JSON.stringify({ error: "additional_consent_required" }),
        { status: 409, headers: { "Content-Type": "application/json" } },
      );
    }
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
