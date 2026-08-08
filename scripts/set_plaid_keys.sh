#!/usr/bin/env bash
# Push Plaid credentials from the macOS keychain to Supabase function secrets.
#
# Plaid issues a DIFFERENT secret per environment, so each one lives in its own
# keychain entry and the environment picks which is read:
#
#   sandbox     -> spendcap-plaid-secret
#   production  -> spendcap-plaid-secret-production
#
# One-time setup after creating a Plaid account (https://dashboard.plaid.com):
#   security add-generic-password -a divinedavis -s spendcap-plaid-client-id -w '<client_id>' -U
#   security add-generic-password -a divinedavis -s spendcap-plaid-secret    -w '<sandbox secret>' -U
#   ./scripts/set_plaid_keys.sh
#
# Going live (needs an approved Plaid Production access request first):
#   security add-generic-password -a divinedavis -s spendcap-plaid-secret-production -w '<production secret>' -U
#   security add-generic-password -a divinedavis -s spendcap-plaid-redirect-uri -w 'https://divinedavis.com/spendcap/oauth/' -U
#   ./scripts/set_plaid_keys.sh production
#
# The credentials are exercised against the target Plaid host BEFORE anything is
# written, so a wrong-environment secret fails here instead of silently turning
# every Link session into INVALID_API_KEYS.

set -euo pipefail

ENV="${1:-sandbox}"
case "$ENV" in
  sandbox)    SECRET_SERVICE=spendcap-plaid-secret ;;
  production) SECRET_SERVICE=spendcap-plaid-secret-production ;;
  *) echo "usage: $0 [sandbox|production]" >&2; exit 2 ;;
esac

CLIENT_ID=$(security find-generic-password -s spendcap-plaid-client-id -w)
if ! SECRET=$(security find-generic-password -s "$SECRET_SERVICE" -w 2>/dev/null); then
  echo "error: keychain entry '$SECRET_SERVICE' not found — add the $ENV secret first (see header)." >&2
  exit 1
fi

# Only production needs the OAuth redirect (Chase, BofA, Wells Fargo, ...).
# It must also be registered in the Plaid dashboard or /link/token/create rejects it.
REDIRECT_URI=$(security find-generic-password -s spendcap-plaid-redirect-uri -w 2>/dev/null || true)
if [ "$ENV" = production ] && [ -z "$REDIRECT_URI" ]; then
  echo "warning: no spendcap-plaid-redirect-uri in the keychain — OAuth banks will not work." >&2
fi

export SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-$(security find-generic-password -s supabase-pat-clockin -w)}"

PLAID_CLIENT_ID="$CLIENT_ID" PLAID_SECRET="$SECRET" PLAID_ENV="$ENV" \
PLAID_REDIRECT_URI="$REDIRECT_URI" python3 - <<'EOF'
import json, os, sys, urllib.error, urllib.request

env = os.environ["PLAID_ENV"]
client_id = os.environ["PLAID_CLIENT_ID"]
secret = os.environ["PLAID_SECRET"]
redirect_uri = os.environ.get("PLAID_REDIRECT_URI", "")
host = {"sandbox": "https://sandbox.plaid.com",
        "production": "https://production.plaid.com"}[env]


def link_token(extra):
    body = {"client_id": client_id, "secret": secret, "client_name": "Spendcap",
            "user": {"client_user_id": "set_plaid_keys-preflight"},
            "products": ["transactions"], "country_codes": ["US"], "language": "en"}
    body.update(extra)
    req = urllib.request.Request(f"{host}/link/token/create", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req)
        return None
    except urllib.error.HTTPError as e:
        err = json.loads(e.read() or b"{}")
        return f"{err.get('error_code')}: {err.get('error_message')}"


# Preflight: bad credentials must not reach Supabase, where they would break
# Link for everyone until someone thinks to look at the secrets.
failure = link_token({})
if failure:
    print(f"refusing to write: {env} credentials rejected by Plaid — {failure}", file=sys.stderr)
    sys.exit(1)
if redirect_uri:
    failure = link_token({"redirect_uri": redirect_uri})
    if failure:
        print(f"refusing to write: redirect_uri {redirect_uri} rejected by Plaid — {failure}\n"
              "Register it under Developers > API in the Plaid dashboard.", file=sys.stderr)
        sys.exit(1)

secrets = [
    {"name": "PLAID_CLIENT_ID", "value": client_id},
    {"name": "PLAID_SECRET", "value": secret},
    {"name": "PLAID_ENV", "value": env},
]
if redirect_uri:
    secrets.append({"name": "PLAID_REDIRECT_URI", "value": redirect_uri})

req = urllib.request.Request(
    "https://api.supabase.com/v1/projects/gmzzbslcsswqjjswoaen/secrets",
    data=json.dumps(secrets).encode(),
    headers={"Authorization": f"Bearer {os.environ['SUPABASE_ACCESS_TOKEN']}",
             "User-Agent": "spendcap-bootstrap/1.0",
             "Content-Type": "application/json"},
    method="POST")
resp = urllib.request.urlopen(req)
names = ", ".join(s["name"] for s in secrets)
print(f"Plaid secrets set: {resp.status} (env={env}) — {names}")
print("Redeploy the edge functions so they pick up the new values:")
print("  supabase functions deploy plaid_create_link_token plaid_create_update_link_token "
      "plaid_exchange_public_token plaid_statements_sync plaid_webhook "
      "--project-ref gmzzbslcsswqjjswoaen")
# The secret-gated ones must keep --no-verify-jwt, so they cannot share the
# line above: a redeploy without it would start rejecting pg_cron, which sends
# a cron secret and no JWT.
print("  supabase functions deploy sync_transactions check_overspend statements_cron "
      "--project-ref gmzzbslcsswqjjswoaen --no-verify-jwt")
EOF
