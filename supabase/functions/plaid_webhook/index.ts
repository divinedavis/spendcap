// Plaid webhook receiver (deployed --no-verify-jwt; Plaid can't send a JWT).
// Only acts on TRANSACTIONS webhooks for item_ids we actually know, so a
// spoofed call can at worst trigger a redundant sync of real data.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { syncItem, checkOverspend } from "../_shared/sync.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

serve(async (req) => {
  try {
    const hook = await req.json();
    if (hook.webhook_type !== "TRANSACTIONS") {
      return new Response(JSON.stringify({ ignored: hook.webhook_type }), { status: 200 });
    }

    const service = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: item } = await service
      .from("plaid_items")
      .select("id, user_id, plaid_item_id, sync_cursor")
      .eq("plaid_item_id", hook.item_id ?? "")
      .eq("status", "active")
      .maybeSingle();
    if (!item) return new Response(JSON.stringify({ ignored: "unknown item" }), { status: 200 });

    await syncItem(service, item);
    await checkOverspend(service);

    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  } catch (err) {
    // Always 200 so Plaid doesn't disable the webhook; errors land in fn logs.
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 200 });
  }
});
