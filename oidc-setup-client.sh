#!/usr/bin/env bash
# Registers an OAuth2/OIDC client in AM and creates a demo end user to
# authenticate as. Idempotent — safe to re-run.
#
# Usage: bash oidc-setup-client.sh
#
# Env overrides:
#   BASE_URL   AM base URL (default: https://poc.example.com/am)
#              Use http://localhost:18080/am if testing via:
#              kubectl port-forward -n poc svc/am 18080:80
#   HOST_HDR   Host header AM expects (default: poc.example.com) — required
#              when BASE_URL points at localhost/port-forward, since AM
#              validates the incoming FQDN against its configured server URL.
#   CURL_OPTS  Extra curl flags (default: -k, to accept the local self-signed
#              cert issued by cert-manager's platform CA)
set -euo pipefail

NAMESPACE=poc
BASE_URL="${BASE_URL:-https://poc.example.com/am}"
HOST_HDR="${HOST_HDR:-poc.example.com}"
CURL_OPTS="${CURL_OPTS:--k}"
CLIENT_ID="${CLIENT_ID:-poc-test-client}"
CLIENT_SECRET="${CLIENT_SECRET:-poc-test-secret-123}"
REDIRECT_URI="${REDIRECT_URI:-https://poc.example.com/callback}"
DEMO_USER="${DEMO_USER:-demouser}"
DEMO_PASSWORD="${DEMO_PASSWORD:-Demo@12345}"

echo "==> AM base URL: $BASE_URL"

echo "==> 1/3 Fetching amadmin password"
ADMIN_PW=$(kubectl get secret am-env-secrets -n "$NAMESPACE" -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)

echo "==> 2/3 Authenticating as amadmin"
ADMIN_TOKEN=$(curl -s $CURL_OPTS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $ADMIN_PW" \
  -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/authenticate" | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)

if [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: failed to authenticate as amadmin. Check BASE_URL/HOST_HDR and that AM is reachable."
  exit 1
fi
echo "    admin session ok"

echo "==> 3/3 Creating OAuth2 client '$CLIENT_ID' (if it doesn't already exist)"
# NOTE: this is deliberately create-only, not an upsert. AM auto-populates
# advanced config (token signing algorithm, etc.) on first creation; a PUT
# full-replace on an *existing* client does not repopulate those defaults and
# silently breaks token issuance ("Unknown Signing Algorithm" on exchange).
# If you need to change an existing client's config, edit it by hand in the
# admin UI/API rather than re-running this script's PUT blindly.
EXISTING_STATUS=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' \
  -H "Accept-API-Version: resource=1.0" \
  -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/realm-config/agents/OAuth2Client/$CLIENT_ID")

if [ "$EXISTING_STATUS" = "200" ]; then
  echo "    client '$CLIENT_ID' already exists, leaving it as-is"
else
  STATUS=$(curl -s $CURL_OPTS -o /tmp/oidc_client_resp.json -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/json' \
    -H "Accept-API-Version: resource=1.0" \
    -H "iPlanetDirectoryPro: $ADMIN_TOKEN" \
    -H "Host: $HOST_HDR" \
    --data "{
      \"clientType\": \"Confidential\",
      \"redirectionUris\": [\"$REDIRECT_URI\"],
      \"scopes\": [\"openid\", \"profile\", \"email\"],
      \"defaultScopes\": [\"openid\"],
      \"responseTypes\": [\"code\"],
      \"grantTypes\": [\"authorization_code\", \"refresh_token\"],
      \"tokenEndpointAuthMethod\": \"client_secret_post\",
      \"isConsentImplied\": true,
      \"userpassword\": \"$CLIENT_SECRET\"
    }" \
    "$BASE_URL/json/realms/root/realm-config/agents/OAuth2Client/$CLIENT_ID")
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "201" ]; then
    echo "    client created (HTTP $STATUS)"
  else
    echo "    ERROR: unexpected status $STATUS"
    cat /tmp/oidc_client_resp.json
    exit 1
  fi
fi

# The identity REST endpoint does NOT enforce username uniqueness on
# _action=create -- calling it twice creates two ambiguous directory entries
# with the same username, which then breaks authentication entirely. Always
# check first and skip if the user already exists.
EXISTING=$(curl -s $CURL_OPTS \
  -H "Accept-API-Version: resource=3.0, protocol=1.0" \
  -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/users?_queryFilter=true&_fields=username" \
  | grep -c "\"$DEMO_USER\"" || true)

if [ "$EXISTING" -gt 0 ]; then
  echo "    demo user '$DEMO_USER' already exists, skipping creation"
else
  echo "    creating demo user '$DEMO_USER'"
  curl -s $CURL_OPTS -X POST \
    -H 'Content-Type: application/json' \
    -H "Accept-API-Version: resource=3.0, protocol=1.0" \
    -H "iPlanetDirectoryPro: $ADMIN_TOKEN" \
    -H "Host: $HOST_HDR" \
    --data "{\"username\":\"$DEMO_USER\",\"userPassword\":\"$DEMO_PASSWORD\",\"cn\":\"Demo User\",\"sn\":\"User\",\"mail\":\"demo@poc.example.com\"}" \
    "$BASE_URL/json/realms/root/users?_action=create" | grep -oE '"code":[0-9]+|"username":"[^"]+"' || true
fi

echo
echo "Done. Client '$CLIENT_ID' / secret '$CLIENT_SECRET' registered."
echo "Demo user '$DEMO_USER' / '$DEMO_PASSWORD' ready."
echo "Next: bash oidc-auth-code-flow.sh"
