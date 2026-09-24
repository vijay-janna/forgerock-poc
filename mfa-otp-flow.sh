#!/usr/bin/env bash
# End-to-end test of the "PocMFA" tree created by mfa-setup-tree.sh -- plays
# the role of an authenticator app by computing RFC 6238 TOTP codes itself:
#   1. Ensure a dedicated test user exists and has no OATH device registered
#      (so the run always starts from first-time registration)
#   2. Log in: username/password -> Registration node returns the otpauth://
#      URI (what the QR code encodes) -> extract the shared secret -> Verifier
#      node asks for a code -> submit the computed TOTP -> expect a session
#   3. Log in again with a WRONG code -> expect HTTP 401 (MFA is enforced)
#   4. Log in again with a fresh correct code (next 30s step -- AM rejects
#      re-use of an already-used step) -> expect a session
#
# Uses its own user (default: mfauser), not demouser, because step 1 deletes
# the user's registered OATH devices -- a phone you registered on demouser via
# the browser is left alone.
#
# Usage: bash mfa-otp-flow.sh
# Env overrides: BASE_URL, HOST_HDR, CURL_OPTS, IDM_URL (see oidc-setup-client.sh),
#                TREE_NAME, MFA_USER, MFA_PASSWORD
# Requires: jq, python3 (both installed in WSL by setup-wsl.sh / Ubuntu default)
set -uo pipefail

NAMESPACE=poc
BASE_URL="${BASE_URL:-https://poc.example.com/am}"
HOST_HDR="${HOST_HDR:-poc.example.com}"
CURL_OPTS="${CURL_OPTS:--k}"
TREE_NAME="${TREE_NAME:-PocMFA}"
MFA_USER="${MFA_USER:-mfauser}"
MFA_PASSWORD="${MFA_PASSWORD:-Mfa@12345}"
. "$(dirname "$0")/lib-idm-user.sh"

AUTH_URL="$BASE_URL/json/realms/root/authenticate?authIndexType=service&authIndexValue=$TREE_NAME"

# totp <base32 secret> -> current 6-digit code (RFC 6238, HMAC-SHA1, 30s step)
totp() {
  python3 - "$1" <<'PY'
import base64, hashlib, hmac, struct, sys, time
s = sys.argv[1].upper().rstrip("=")
key = base64.b32decode(s + "=" * (-len(s) % 8))
h = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
o = h[-1] & 0x0F
print("%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000))
PY
}

# auth_step <json body> -> response body on stdout, HTTP status in $STEP_STATUS_FILE
STEP_STATUS_FILE=$(mktemp)
trap 'rm -f "$STEP_STATUS_FILE"' EXIT
auth_step() {
  curl -s $CURL_OPTS -X POST -o - -w '\n%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "Accept-API-Version: resource=2.1, protocol=1.0" \
    -H "Host: $HOST_HDR" --data "$1" "$AUTH_URL" \
    | { body=$(cat); echo "${body##*$'\n'}" > "$STEP_STATUS_FILE"; echo "${body%$'\n'*}"; }
}
step_status() { cat "$STEP_STATUS_FILE"; }

# login_with_password -> response after the username/password page
login_with_password() {
  local r
  r=$(auth_step '{}')
  echo "$r" | jq --arg u "$MFA_USER" --arg p "$MFA_PASSWORD" '
    (.callbacks[] | select(.type == "NameCallback")     | .input[0].value) = $u |
    (.callbacks[] | select(.type == "PasswordCallback") | .input[0].value) = $p' \
    | { body=$(cat); auth_step "$body"; }
}

# submit_code <verifier response> <code> -> final response
submit_code() {
  echo "$1" | jq --arg c "$2" '
    (.callbacks[] | select(.type == "NameCallback" or .type == "PasswordCallback") | .input[0].value) = $c' \
    | { body=$(cat); auth_step "$body"; }
}

callback_types() { echo "$1" | jq -c '[.callbacks[]?.type]'; }

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "$2" | head -c 600 && echo; exit 1; }

echo "==> AM base URL: $BASE_URL (tree: $TREE_NAME)"

echo "==> 1/4 Preparing test user '$MFA_USER'"
ADMIN_PW=$(kubectl get secret am-env-secrets -n "$NAMESPACE" -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)
ADMIN_TOKEN=$(curl -s $CURL_OPTS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $ADMIN_PW" \
  -H "Accept-API-Version: resource=2.0, protocol=1.0" \
  -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/authenticate" | jq -r '.tokenId // empty')
[ -n "$ADMIN_TOKEN" ] || fail "could not authenticate as amadmin (check BASE_URL/HOST_HDR)"
ADMIN_HDRS=(-H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR" -H 'Content-Type: application/json')

# Created through IDM (see lib-idm-user.sh) so AM identifies the user by
# fr-idm-uuid -- required for the session to work in the end-user UI.
ensure_idm_user "$MFA_USER" "$MFA_PASSWORD" "Otp" "Tester" "mfa@poc.example.com" || exit 1
MFA_UUID=$(idm_curl "$IDM_URL/managed/user?_queryFilter=userName%20eq%20%22$MFA_USER%22&_fields=_id" \
  | jq -r '.result[0]._id // empty')
[ -n "$MFA_UUID" ] || fail "could not look up '$MFA_USER' in IDM"

# AM identifies platform users by fr-idm-uuid (its users-search-attribute)
DEVICES_URL="$BASE_URL/json/realms/root/users/$MFA_UUID/devices/2fa/oath"
for dev in $(curl -s $CURL_OPTS "${ADMIN_HDRS[@]}" -H "Accept-API-Version: resource=1.0" \
               "$DEVICES_URL?_queryFilter=true" | jq -r '.result[]?._id'); do
  curl -s $CURL_OPTS -X DELETE "${ADMIN_HDRS[@]}" -H "Accept-API-Version: resource=1.0" \
    "$DEVICES_URL/$dev" >/dev/null
  echo "    removed existing OATH device $dev"
done

echo "==> 2/4 First login: register device, then verify"
R=$(login_with_password)
URI=$(echo "$R" | jq -r '.callbacks[]? | select(.type == "HiddenValueCallback")
                         | select(any(.output[]; .name == "id" and .value == "mfaDeviceRegistration"))
                         | .output[] | select(.name == "value") | .value')
[ -n "$URI" ] || fail "expected OATH registration (QR code) step, got $(callback_types "$R")" "$R"
echo "    otpauth URI: $URI"
SECRET=$(echo "$URI" | sed -E 's/.*[?&]secret=([^&]*).*/\1/; s/%3[Dd]/=/g')

# Registration page: the ConfirmationCallback's default option is "Next" -- submit as-is
R=$(auth_step "$R")
echo "$R" | jq -e '.callbacks' >/dev/null || fail "expected verifier step after registration" "$R"
CODE=$(totp "$SECRET")
USED_STEP=$(( $(date +%s) / 30 ))
echo "    verifier asks for code ($(callback_types "$R")) -> sending $CODE"
R=$(submit_code "$R" "$CODE")
[ -n "$(echo "$R" | jq -r '.tokenId // empty')" ] || fail "registration login did not return a session (HTTP $(step_status))" "$R"
echo "    OK: session issued, device registered"

echo "==> 3/4 Second login with a WRONG code (expect rejection)"
R=$(login_with_password)
echo "$R" | jq -e '.callbacks' >/dev/null || fail "expected verifier step" "$R"
echo "$R" | jq -e '.callbacks[] | select(.type == "HiddenValueCallback")' >/dev/null \
  && fail "was asked to register again -- device was not stored" "$R"
WRONG=$(printf '%06d' $(( (10#$(totp "$SECRET") + 500000) % 1000000 )))
R=$(submit_code "$R" "$WRONG")
STATUS=$(step_status)
if [ "$STATUS" = "401" ] && [ -z "$(echo "$R" | jq -r '.tokenId // empty')" ]; then
  echo "    OK: wrong code $WRONG rejected (HTTP 401)"
else
  fail "wrong code was not rejected (HTTP $STATUS)" "$R"
fi

echo "==> 4/4 Third login with a fresh correct code"
while [ $(( $(date +%s) / 30 )) -le "$USED_STEP" ]; do
  echo "    waiting $(( 30 - $(date +%s) % 30 ))s for the next TOTP step (codes are single-use)"
  sleep $(( 30 - $(date +%s) % 30 + 1 ))
done
R=$(login_with_password)
echo "$R" | jq -e '.callbacks' >/dev/null || fail "expected verifier step" "$R"
CODE=$(totp "$SECRET")
R=$(submit_code "$R" "$CODE")
TOKEN=$(echo "$R" | jq -r '.tokenId // empty')
[ -n "$TOKEN" ] || fail "correct code $CODE was rejected (HTTP $(step_status))" "$R"
echo "    OK: code $CODE accepted, session ${TOKEN:0:15}..."

echo
echo "PASS: password + TOTP MFA enforced by tree '$TREE_NAME' for '$MFA_USER'."
echo "To try it with a real authenticator app, open in a browser (as demouser or any user):"
echo "  https://$HOST_HDR/am/XUI/?realm=/&authIndexType=service&authIndexValue=$TREE_NAME"
