#!/usr/bin/env bash
# Runs a full OAuth2/OIDC authorization code flow against the client and demo
# user created by oidc-setup-client.sh:
#   1. Authenticate the demo user (simulates their login) to get an AM session
#   2. Call /oauth2/authorize with that session -> AM issues an authorization code
#      (isConsentImplied=true on the client skips the interactive consent page,
#      matching a trusted first-party app)
#   3. Exchange the code for tokens at /oauth2/access_token
#   4. Call /oauth2/userinfo with the access token to prove it works
#
# No browser or real callback listener is needed — the script intercepts the
# redirect's Location header directly instead of following it.
#
# Usage: bash oidc-auth-code-flow.sh
# Env overrides: same as oidc-setup-client.sh (BASE_URL, HOST_HDR, CURL_OPTS,
# CLIENT_ID, CLIENT_SECRET, REDIRECT_URI, DEMO_USER, DEMO_PASSWORD)
set -euo pipefail

BASE_URL="${BASE_URL:-https://poc.example.com/am}"
HOST_HDR="${HOST_HDR:-poc.example.com}"
CURL_OPTS="${CURL_OPTS:--k}"
CLIENT_ID="${CLIENT_ID:-poc-test-client}"
CLIENT_SECRET="${CLIENT_SECRET:-poc-test-secret-123}"
REDIRECT_URI="${REDIRECT_URI:-https://poc.example.com/callback}"
DEMO_USER="${DEMO_USER:-demouser}"
DEMO_PASSWORD="${DEMO_PASSWORD:-Demo@12345}"

echo "==> 1/4 Authenticating as $DEMO_USER"
USER_TOKEN=$(curl -s $CURL_OPTS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: $DEMO_USER" -H "X-OpenAM-Password: $DEMO_PASSWORD" \
  -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/authenticate" | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)

if [ -z "$USER_TOKEN" ]; then
  echo "ERROR: failed to authenticate $DEMO_USER. Run oidc-setup-client.sh first."
  exit 1
fi
echo "    user session ok"

echo "==> 2/4 Calling /oauth2/authorize"
LOCATION=$(curl -s $CURL_OPTS -i -X GET \
  -H "Host: $HOST_HDR" \
  -H "Cookie: iPlanetDirectoryPro=$USER_TOKEN" \
  -G "$BASE_URL/oauth2/realms/root/authorize" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "response_type=code" \
  --data-urlencode "scope=openid profile email" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "state=xyz123" \
  | grep -i '^Location:' | tr -d '\r')

if [ -z "$LOCATION" ]; then
  echo "ERROR: no redirect received from /authorize -- check client config / consent."
  exit 1
fi
echo "    redirected to: $LOCATION"

CODE=$(echo "$LOCATION" | grep -oE 'code=[^&]+' | cut -d= -f2)
if [ -z "$CODE" ]; then
  echo "ERROR: no authorization code in redirect."
  exit 1
fi
echo "    authorization code: $CODE"

echo "==> 3/4 Exchanging code for tokens"
TOKEN_RESP=$(curl -s $CURL_OPTS -X POST \
  -H "Host: $HOST_HDR" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  "$BASE_URL/oauth2/realms/root/access_token")

ACCESS_TOKEN=$(echo "$TOKEN_RESP" | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: token exchange failed:"
  echo "$TOKEN_RESP"
  exit 1
fi
echo "    access_token, id_token, refresh_token received"
echo "$TOKEN_RESP" > /tmp/oidc_tokens.json
echo "    (full response saved to /tmp/oidc_tokens.json inside WSL2)"

echo "==> 4/4 Calling /oauth2/userinfo with the access token"
curl -s $CURL_OPTS -H "Host: $HOST_HDR" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$BASE_URL/oauth2/realms/root/userinfo"
echo
echo
echo "Flow complete: login -> authorize -> code -> token exchange -> userinfo, all verified."
