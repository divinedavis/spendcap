#!/usr/bin/env bash
# Spendcap — turn the Plaid OAuth redirect URI on or off.
#
# OAuth banks (Chase, BofA, Wells Fargo, Capital One, US Bank, Schwab, PNC)
# require a redirect_uri. Plaid rejects any URI that is not registered in the
# dashboard first — /link/token/create fails with:
#
#   INVALID_FIELD  OAuth redirect URI must be configured in the developer
#                  dashboard
#
# which breaks bank linking entirely. So this is a deliberate two-step:
#
#   1. Register https://divinedavis.com/spendcap/oauth/ at
#      https://dashboard.plaid.com/developers/api  ->  "Allowed redirect URIs"
#   2. ./scripts/set_oauth_redirect.sh on
#
# Usage:
#   ./scripts/set_oauth_redirect.sh on     # set the secret (after registering)
#   ./scripts/set_oauth_redirect.sh off    # unset it (non-OAuth banks only)
#   ./scripts/set_oauth_redirect.sh test   # verify link-token creation works

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_REF="gmzzbslcsswqjjswoaen"
REDIRECT_URI="https://divinedavis.com/spendcap/oauth/"
MODE="${1:-test}"

export SUPABASE_ACCESS_TOKEN="${SUPABASE_ACCESS_TOKEN:-$(security find-generic-password -s supabase-pat-clockin -w)}"
API="https://api.supabase.com/v1/projects/$PROJECT_REF/secrets"
# A non-default User-Agent is required or Cloudflare 403s the management API.
UA="spendcap-bootstrap/1.0"

verify_link_token() {
    local anon creds email pass jwt resp
    anon=$(security find-generic-password -s spendcap-supabase-anon -w)
    creds=$(security find-generic-password -s spendcap-test-account -w)
    email=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['email'])")
    pass=$(echo "$creds" | python3 -c "import json,sys;print(json.load(sys.stdin)['password'])")
    jwt=$(curl -s -X POST "https://$PROJECT_REF.supabase.co/auth/v1/token?grant_type=password" \
        -H "apikey: $anon" -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$pass\"}" \
        | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
    if [[ -z "$jwt" ]]; then echo "error: could not sign in as the test user" >&2; return 1; fi
    resp=$(curl -s -X POST "https://$PROJECT_REF.supabase.co/functions/v1/plaid_create_link_token" \
        -H "Authorization: Bearer $jwt" -H "apikey: $anon" \
        -H "Content-Type: application/json" -d '{}')
    echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'link_token' in d:
    print('  OK — link_token issued')
else:
    print('  FAILED —', json.dumps(d)[:300])
    raise SystemExit(1)
"
}

case "$MODE" in
    on)
        echo "==> setting PLAID_REDIRECT_URI=$REDIRECT_URI"
        curl -s -X POST "$API" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            -H "User-Agent: $UA" -H "Content-Type: application/json" \
            -d "[{\"name\":\"PLAID_REDIRECT_URI\",\"value\":\"$REDIRECT_URI\"}]" >/dev/null
        sleep 5
        echo "==> verifying link-token creation still works"
        if verify_link_token; then
            echo "==> OAuth redirect is ON"
        else
            echo "" >&2
            echo "The URI is probably not registered in the Plaid dashboard yet." >&2
            echo "Register it, then re-run. Turning it back off so linking keeps working." >&2
            "$0" off
            exit 1
        fi
        ;;
    off)
        echo "==> unsetting PLAID_REDIRECT_URI"
        curl -s -X DELETE "$API" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
            -H "User-Agent: $UA" -H "Content-Type: application/json" \
            -d '["PLAID_REDIRECT_URI"]' >/dev/null
        sleep 3
        verify_link_token || true
        echo "==> OAuth redirect is OFF (non-OAuth banks only)"
        ;;
    test)
        echo "==> testing link-token creation"
        verify_link_token
        ;;
    *)
        echo "usage: $0 [on|off|test]" >&2
        exit 1
        ;;
esac
