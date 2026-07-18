// JWT-gated: creates a Plaid Link token for the signed-in user.
import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { plaid, plaidConfigured } from "../_shared/plaid.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return new Response("Unauthorized", { status: 401 });

    if (!plaidConfigured()) {
      return new Response(JSON.stringify({ error: "plaid_not_configured" }), {
        status: 503, headers: { "Content-Type": "application/json" },
      });
    }

    const resp = await plaid("/link/token/create", {
      client_name: "Spendcap",
      user: { client_user_id: user.id },
      products: ["transactions"],
      country_codes: ["US"],
      language: "en",
      webhook: `${SUPABASE_URL}/functions/v1/plaid_webhook`,
    });

    return new Response(JSON.stringify({ link_token: resp.link_token }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
