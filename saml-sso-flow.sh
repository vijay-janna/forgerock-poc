#!/usr/bin/env bash
# Runs a full SP-initiated SAML SSO flow against the AM IdP + SimpleSAMLphp
# SP test app ("saml-sp") deployed in the poc namespace:
#   1. Authenticate the demo user directly against AM (simulates their login)
#   2. Hit the SP's authenticate.php -> SP redirects to AM's SSORedirect
#      endpoint with a SAMLRequest
#   3. Present the AM session cookie at that URL -> AM should redirect back
#      to the SP's ACS endpoint with an auto-submit form containing a
#      SAMLResponse
#   4. Extract the SAMLResponse/RelayState from that form
#   5. POST it to the SP's ACS endpoint (completes the SSO handshake)
#   6. Check the SP's session-test page to confirm the user is logged in
#
# Requires: `sudo -E kubectl port-forward -n ingress-nginx
# svc/ingress-nginx-controller 443:443 80:80` already running in another WSL
# terminal (see deploy.sh notes) -- this script talks to https://poc.example.com
# via that tunnel, using --resolve since WSL doesn't see the Windows hosts file.
#
# Usage: bash saml-sso-flow.sh
# Env overrides: HOST_HDR, CURL_OPTS, RESOLVE_IP, DEMO_USER, DEMO_PASSWORD
set -uo pipefail

HOST_HDR="${HOST_HDR:-poc.example.com}"
RESOLVE_IP="${RESOLVE_IP:-127.0.0.1}"
CURL_OPTS="${CURL_OPTS:--k}"
DEMO_USER="${DEMO_USER:-demouser}"
DEMO_PASSWORD="${DEMO_PASSWORD:-Demo@12345}"
RESOLVE="--resolve $HOST_HDR:443:$RESOLVE_IP"
BASE="https://$HOST_HDR"

# case-insensitive Location header extraction (nginx/AM may send either case)
get_location() {
  grep -io '^location:.*' | sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r'
}

echo "==> 1/6 Authenticating as $DEMO_USER against AM"
USER_TOKEN=$(curl -s $CURL_OPTS $RESOLVE -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: $DEMO_USER" -H "X-OpenAM-Password: $DEMO_PASSWORD" \
  -H "Host: $HOST_HDR" "$BASE/am/json/realms/root/authenticate" \
  | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)

if [ -z "$USER_TOKEN" ]; then
  echo "ERROR: failed to authenticate $DEMO_USER against AM."
  exit 1
fi
echo "    AM session: ${USER_TOKEN:0:15}..."

echo "==> 2/6 SP-initiated SSO: hitting SP authenticate.php"
rm -f /tmp/sp_cookies.txt
SP_REDIRECT=$(curl -s $CURL_OPTS $RESOLVE -i -c /tmp/sp_cookies.txt -H "Host: $HOST_HDR" \
  "$BASE/simplesaml/module.php/core/authenticate.php?as=default-sp&ReturnTo=%2Fsimplesaml%2F" \
  | get_location)

if [ -z "$SP_REDIRECT" ]; then
  echo "ERROR: SP did not redirect to AM. Check saml-sp pod / ingress."
  exit 1
fi
echo "    SP redirect -> $SP_REDIRECT"

echo "==> 3/6 Presenting AM session cookie at AM's SSO endpoint (up to 3 hops)"
CURRENT="$SP_REDIRECT"
for i in 1 2 3; do
  HDRS=$(curl -s $CURL_OPTS $RESOLVE -i -H "Host: $HOST_HDR" \
    -H "Cookie: iPlanetDirectoryPro=$USER_TOKEN" "$CURRENT")
  STATUS_LINE=$(echo "$HDRS" | head -1)
  echo "    hop $i -> $STATUS_LINE"
  if echo "$STATUS_LINE" | grep -qE ' [45][0-9][0-9] '; then
    echo "ERROR: AM rejected the SAML request (see status above)."
    echo "$HDRS" > /tmp/am_final_response.html
    echo "    full response saved to /tmp/am_final_response.html inside WSL2"
    echo "    check AM logs: kubectl logs -n poc deploy/am --tail=50 | grep -i saml"
    exit 1
  fi
  NEXT=$(echo "$HDRS" | get_location)
  if [ -z "$NEXT" ]; then
    echo "$HDRS" > /tmp/am_final_response.html
    break
  fi
  CURRENT="$NEXT"
done

echo "==> 4/6 Extracting SAMLResponse/RelayState from the auto-submit form"
# AM's auto-submit form line-wraps the base64 SAMLResponse using literal HTML
# character references (&#xd;&#xa; per line) instead of real whitespace --
# these must be HTML-unescaped and stripped, or the leftover '&#xd;' etc. text
# corrupts the base64 alignment once decoded on the SP side.
python3 -c "
import re, html
with open('/tmp/am_final_response.html') as f:
    content = f.read()
saml = re.search(r'name=\"SAMLResponse\" value=\"([^\"]+)\"', content)
relay = re.search(r'name=\"RelayState\" value=\"([^\"]*)\"', content)
action = re.search(r'<form[^>]+action=\"([^\"]+)\"', content)
print('ACTION=' + (action.group(1) if action else '(none)'))
print('HAS_SAMLRESPONSE=' + ('yes' if saml else 'no'))
saml_clean = re.sub(r'\s+', '', html.unescape(saml.group(1))) if saml else ''
relay_clean = html.unescape(relay.group(1)) if relay else ''
open('/tmp/saml_response.txt', 'w').write(saml_clean)
open('/tmp/relay_state.txt', 'w').write(relay_clean)
"

if [ ! -s /tmp/saml_response.txt ]; then
  echo "ERROR: no SAMLResponse found in AM's response. Flow stopped here."
  echo "    inspect /tmp/am_final_response.html inside WSL2 for the actual error page."
  exit 1
fi
echo "    SAMLResponse captured"

echo "==> 5/6 POSTing SAMLResponse to the SP's ACS endpoint"
SAML_RESPONSE=$(cat /tmp/saml_response.txt)
RELAY_STATE=$(cat /tmp/relay_state.txt)
curl -s $CURL_OPTS $RESOLVE -i -b /tmp/sp_cookies.txt -c /tmp/sp_cookies.txt \
  -H "Host: $HOST_HDR" \
  --data-urlencode "SAMLResponse=$SAML_RESPONSE" \
  --data-urlencode "RelayState=$RELAY_STATE" \
  "$BASE/simplesaml/module.php/saml/sp/saml2-acs.php/default-sp" \
  > /tmp/acs_response.html
head -3 /tmp/acs_response.html

echo
echo "==> 6/6 Verifying the SP session (re-hitting authenticate.php with the SP session cookie)"
# The SP image doesn't ship the 'admin' module (module.php/admin/test/* 404s).
# With an active session, SimpleSAMLphp serves its status page directly (HTTP
# 200, showing the federated attributes) instead of redirecting back to AM.
curl -s $CURL_OPTS $RESOLVE -b /tmp/sp_cookies.txt -H "Host: $HOST_HDR" \
  "$BASE/simplesaml/module.php/core/authenticate.php?as=default-sp&ReturnTo=%2Fsimplesaml%2F" \
  > /tmp/sp_test_page.html

if grep -q 'SPNameQualifier' /tmp/sp_test_page.html; then
  echo "    SUCCESS: $DEMO_USER has an active federated SP session (see /tmp/sp_test_page.html)"
else
  echo "    Could not confirm an authenticated session -- inspect /tmp/sp_test_page.html"
fi
