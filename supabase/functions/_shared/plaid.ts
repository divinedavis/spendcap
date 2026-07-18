// Plaid REST helper shared by Spendcap edge functions.
// PLAID_ENV selects the host; credentials come from function secrets.

const PLAID_ENV = Deno.env.get("PLAID_ENV") ?? "sandbox";
const PLAID_CLIENT_ID = Deno.env.get("PLAID_CLIENT_ID") ?? "";
const PLAID_SECRET = Deno.env.get("PLAID_SECRET") ?? "";

const HOSTS: Record<string, string> = {
  sandbox: "https://sandbox.plaid.com",
  production: "https://production.plaid.com",
};

export function plaidConfigured(): boolean {
  return PLAID_CLIENT_ID.length > 0 && PLAID_SECRET.length > 0;
}

export async function plaid<T = any>(path: string, body: Record<string, unknown>): Promise<T> {
  const resp = await fetch(`${HOSTS[PLAID_ENV] ?? HOSTS.sandbox}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "PLAID-CLIENT-ID": PLAID_CLIENT_ID,
      "PLAID-SECRET": PLAID_SECRET,
    },
    body: JSON.stringify(body),
  });
  const json = await resp.json();
  if (!resp.ok) {
    throw new Error(`plaid ${path} ${resp.status}: ${json.error_code ?? ""} ${json.error_message ?? ""}`);
  }
  return json as T;
}

export function toCents(amount: number): number {
  return Math.round(amount * 100);
}
