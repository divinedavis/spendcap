#!/usr/bin/env bash
# Push Plaid credentials from the macOS keychain to Supabase function secrets.
#
# One-time setup after creating a Plaid account (https://dashboard.plaid.com):
#   security add-generic-password -a divinedavis -s spendcap-plaid-client-id -w '<client_id>' -U
#   security add-generic-password -a divinedavis -s spendcap-plaid-secret    -w '<sandbox secret>' -U
#   ./scripts/set_plaid_keys.sh
#
# PLAID_ENV stays 'sandbox' until launch; pass 'production' as $1 to switch
# (requires the production secret in the keychain entry).

set -euo pipefail

ENV="${1:-sandbox}"
CLIENT_ID=$(security find-generic-password -s spendcap-plaid-client-id -w)
SECRET=$(security find-generic-password -s spendcap-plaid-secret -w)
export SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-$(security find-generic-password -s supabase-pat-clockin -w)}"

PLAID_CLIENT_ID="$CLIENT_ID" PLAID_SECRET="$SECRET" PLAID_ENV="$ENV" python3 - <<'EOF'
import json, os, urllib.request
secrets = [
    {"name": "PLAID_CLIENT_ID", "value": os.environ["PLAID_CLIENT_ID"]},
    {"name": "PLAID_SECRET", "value": os.environ["PLAID_SECRET"]},
    {"name": "PLAID_ENV", "value": os.environ["PLAID_ENV"]},
]
req = urllib.request.Request(
    "https://api.supabase.com/v1/projects/gmzzbslcsswqjjswoaen/secrets",
    data=json.dumps(secrets).encode(),
    headers={"Authorization": f"Bearer {os.environ['SUPABASE_ACCESS_TOKEN']}",
             "User-Agent": "spendcap-bootstrap/1.0",
             "Content-Type": "application/json"},
    method="POST")
resp = urllib.request.urlopen(req)
print("Plaid secrets set:", resp.status, f"(env={os.environ['PLAID_ENV']})")
EOF
