// Ending a bank connection at Plaid (/item/remove).
//
// Deleting our plaid_items row only forgets the access token; the Item stays
// live at Plaid until /item/remove is called. Shared by the JWT-gated
// plaid_remove_item (Disconnect, Delete Account) and the secret-gated
// plaid_removal_cron (drains the queue the 0030 trigger fills).
import { plaid } from "./plaid.ts";

// Plaid answers these when the token no longer refers to a live Item — it was
// already removed, or it is a sandbox token presented to production. Either
// way there is nothing left to remove, so they count as done.
const ALREADY_GONE = ["ITEM_NOT_FOUND", "INVALID_ACCESS_TOKEN"];

export type RemoveOutcome = "removed" | "already_gone" | "failed";

export async function removeAtPlaid(accessToken: string): Promise<{ outcome: RemoveOutcome; error?: string }> {
  try {
    await plaid("/item/remove", { access_token: accessToken });
    return { outcome: "removed" };
  } catch (err) {
    const msg = String(err);
    if (ALREADY_GONE.some((code) => msg.includes(code))) return { outcome: "already_gone" };
    // Never echo the token; plaid() errors carry only path, status and code.
    return { outcome: "failed", error: msg.slice(0, 300) };
  }
}
