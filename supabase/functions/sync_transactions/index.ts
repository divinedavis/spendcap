// Cron fallback sync (deployed --no-verify-jwt, gated by x-cron-secret).
// Syncs every active item, then runs the overspend check.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncAllItems, checkOverspend } from "../_shared/sync.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
if (!CRON_SECRET) throw new Error("CRON_SECRET env var is required");

serve(async (req) => {
  try {
    if ((req.headers.get("x-cron-secret") ?? "") !== CRON_SECRET) {
      return new Response("Forbidden", { status: 403 });
    }
    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const sync = await syncAllItems(service);
    const alerts = await checkOverspend(service);
    return new Response(JSON.stringify({ ...sync, ...alerts }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
