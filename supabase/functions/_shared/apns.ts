// APNs helper — same pattern as WorkComp+'s send_message_push.
// Tries production then sandbox, purges dead tokens.
import { SignJWT, importPKCS8 } from "https://deno.land/x/jose@v4.14.4/index.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY")!;

export const BUNDLE_ID = "com.divinedavis.spendcap";
const APNS_HOSTS = ["https://api.push.apple.com", "https://api.sandbox.push.apple.com"];

async function getApnsToken(): Promise<string> {
  const key = await importPKCS8(APNS_PRIVATE_KEY, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: APNS_KEY_ID })
    .setIssuer(APNS_TEAM_ID)
    .setIssuedAt()
    .setExpirationTime("1h")
    .sign(key);
}

export async function pushToUser(
  supabase: SupabaseClient,
  userId: string,
  payload: { title: string; body: string; threadId: string; extra?: Record<string, unknown> },
): Promise<number> {
  const { data: tokens } = await supabase
    .from("device_push_tokens").select("device_token").eq("user_id", userId);
  if (!tokens?.length) return 0;

  const body = JSON.stringify({
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
      "thread-id": payload.threadId,
    },
    ...(payload.extra ?? {}),
  });
  const apnsToken = await getApnsToken();

  let sent = 0;
  await Promise.allSettled((tokens as { device_token: string }[]).map(async ({ device_token }) => {
    for (const host of APNS_HOSTS) {
      const resp = await fetch(`${host}/3/device/${device_token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${apnsToken}`,
          "apns-topic": BUNDLE_ID,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body,
      });
      if (resp.status === 200) { sent++; return; }
      const text = await resp.text();
      let reason = "";
      try { reason = (JSON.parse(text)?.reason ?? "") as string; } catch (_) { /* not json */ }
      if (resp.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
        try { await supabase.from("device_push_tokens").delete().eq("device_token", device_token); } catch (_) { /* ignore */ }
        return;
      }
    }
  }));
  return sent;
}
