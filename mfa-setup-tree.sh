#!/usr/bin/env bash
# Creates an MFA authentication tree ("PocMFA") in AM's root realm that adds a
# TOTP one-time-password step (OATH nodes -- works with Google Authenticator,
# Microsoft Authenticator, the ForgeRock/Ping Authenticator, etc.) after the
# usual username/password check. Idempotent -- safe to re-run; every node has
# a fixed ID and is written with PUT.
#
#   [Username + Password page] -> [Data Store Decision]
#        true  -> [OATH Token Verifier]
#                   success        -> Success
#                   notRegistered  -> [OATH Registration] -> (success) back to Verifier
#                   failure        -> Failure
#        false -> Failure
#
# First login: the user has no device yet, so the Registration node shows a QR
# code (otpauth:// URI). After scanning it they're sent straight to the
# Verifier to prove the device works. Later logins go password -> code.
#
# The platform's default "Login" tree is NOT modified; the new tree is only
# used when selected explicitly:
#   browser: https://poc.example.com/am/XUI/?realm=/&authIndexType=service&authIndexValue=PocMFA
#   REST:    POST /am/json/realms/root/authenticate?authIndexType=service&authIndexValue=PocMFA
#
# Usage: bash mfa-setup-tree.sh     (end-to-end test: bash mfa-otp-flow.sh)
#
# Env overrides (same conventions as oidc-setup-client.sh):
#   BASE_URL   AM base URL (default: https://poc.example.com/am)
#              Use http://localhost:18080/am if testing via:
#              kubectl port-forward -n poc svc/am 18080:80
#   HOST_HDR   Host header AM expects (default: poc.example.com)
#   CURL_OPTS  Extra curl flags (default: -k)
#   TREE_NAME  Tree name (default: PocMFA)
#   ISSUER     Issuer label shown in the authenticator app (default: Ping PoC)
set -euo pipefail

NAMESPACE=poc
BASE_URL="${BASE_URL:-https://poc.example.com/am}"
HOST_HDR="${HOST_HDR:-poc.example.com}"
CURL_OPTS="${CURL_OPTS:--k}"
TREE_NAME="${TREE_NAME:-PocMFA}"
ISSUER="${ISSUER:-Ping PoC}"

# Fixed node IDs so re-runs overwrite rather than duplicate
PAGE_ID="6d0f1a10-0001-4c3e-9a51-2f4b8e0c7a01"
USER_ID="6d0f1a10-0007-4c3e-9a51-2f4b8e0c7a07"
PASS_ID="6d0f1a10-0008-4c3e-9a51-2f4b8e0c7a08"
# Earlier versions used the classic Username/Password Collector nodes under
# these IDs; they're deleted below if still present.
OLD_COLLECTOR_NODES="UsernameCollectorNode/6d0f1a10-0002-4c3e-9a51-2f4b8e0c7a02 PasswordCollectorNode/6d0f1a10-0003-4c3e-9a51-2f4b8e0c7a03"
DSD_ID="6d0f1a10-0004-4c3e-9a51-2f4b8e0c7a04"
VERIFY_ID="6d0f1a10-0005-4c3e-9a51-2f4b8e0c7a05"
REGISTER_ID="6d0f1a10-0006-4c3e-9a51-2f4b8e0c7a06"
# AM's built-in static terminal nodes (same IDs in every realm)
SUCCESS_ID="70e691a5-1e33-4ac3-a356-e7b6d60d92e0"
FAILURE_ID="e301438c-0bd0-429c-ab0c-66126501069a"

echo "==> AM base URL: $BASE_URL"

echo "==> 1/3 Authenticating as amadmin"
ADMIN_PW=$(kubectl get secret am-env-secrets -n "$NAMESPACE" -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)
ADMIN_TOKEN=$(curl -s $CURL_OPTS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $ADMIN_PW" \
  -H "Accept-API-Version: resource=2.0, protocol=1.0" \
  -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/authenticate" | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)

if [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: failed to authenticate as amadmin. Check BASE_URL/HOST_HDR and that AM is reachable."
  exit 1
fi
echo "    admin session ok"

TREES_URL="$BASE_URL/json/realms/root/realm-config/authentication/authenticationtrees"

# put_config <path under authenticationtrees> <json>
put_config() {
  local status
  status=$(curl -s $CURL_OPTS -o /tmp/mfa_put_resp.json -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/json' \
    -H "Accept-API-Version: resource=1.0" \
    -H "iPlanetDirectoryPro: $ADMIN_TOKEN" \
    -H "Host: $HOST_HDR" \
    --data "$2" "$TREES_URL/$1")
  if [ "$status" != "200" ] && [ "$status" != "201" ]; then
    echo "    ERROR: PUT $1 returned HTTP $status"
    cat /tmp/mfa_put_resp.json; echo
    exit 1
  fi
  echo "    $1 (HTTP $status)"
}

echo "==> 2/3 Creating nodes"
# Platform Username/Password nodes (same as the stock Login tree), NOT the
# classic Username/Password Collectors: the platform nodes resolve the user to
# their IDM identity (fr-idm-uuid), so the session/token subject is the UUID.
# With the classic collectors the subject is the bare username, IDM can't map
# it to managed/user, and the end-user UI dashboard stays empty.
put_config "nodes/ValidatedUsernameNode/$USER_ID" '{"usernameAttribute": "userName", "validateInput": false}'
put_config "nodes/ValidatedPasswordNode/$PASS_ID" '{"passwordAttribute": "password", "validateInput": false}'
put_config "nodes/PageNode/$PAGE_ID" "{
  \"nodes\": [
    {\"_id\": \"$USER_ID\", \"nodeType\": \"ValidatedUsernameNode\", \"displayName\": \"Platform Username\"},
    {\"_id\": \"$PASS_ID\", \"nodeType\": \"ValidatedPasswordNode\", \"displayName\": \"Platform Password\"}
  ],
  \"pageHeader\": {\"en\": \"Sign In (MFA)\"},
  \"pageDescription\": {}
}"
put_config "nodes/DataStoreDecisionNode/$DSD_ID" '{}'
# TOTP, 6 digits, 30s steps, SHA1 -- the defaults every authenticator app supports.
# Recovery codes are turned off to keep the flow scriptable; see INSTALLATION.md
# (MFA section) for how to add them.
put_config "nodes/OathTokenVerifierNode/$VERIFY_ID" '{
  "algorithm": "TOTP",
  "totpTimeInterval": 30,
  "totpTimeSteps": 2,
  "totpHashAlgorithm": "HMAC_SHA1",
  "maximumAllowedClockDrift": 5,
  "hotpWindowSize": 100,
  "isRecoveryCodeAllowed": false
}'
put_config "nodes/OathRegistrationNode/$REGISTER_ID" "{
  \"algorithm\": \"TOTP\",
  \"passwordLength\": \"SIX_DIGITS\",
  \"totpTimeInterval\": 30,
  \"totpHashAlgorithm\": \"HMAC_SHA1\",
  \"minSharedSecretLength\": 32,
  \"truncationOffset\": -1,
  \"addChecksum\": false,
  \"issuer\": \"$ISSUER\",
  \"accountName\": \"USERNAME\",
  \"bgColor\": \"032b75\",
  \"imgUrl\": \"\",
  \"scanQRCodeMessage\": {},
  \"generateRecoveryCodes\": false,
  \"postponeDeviceProfileStorage\": false
}"

echo "==> 3/3 Creating tree '$TREE_NAME'"
put_config "trees/$TREE_NAME" "{
  \"description\": \"Username/password followed by TOTP one-time password (OATH)\",
  \"enabled\": true,
  \"uiConfig\": {\"categories\": \"[\\\"Authentication\\\"]\"},
  \"entryNodeId\": \"$PAGE_ID\",
  \"nodes\": {
    \"$PAGE_ID\":     {\"displayName\": \"Username + Password\", \"nodeType\": \"PageNode\",
                       \"x\": 140, \"y\": 60,  \"connections\": {\"outcome\": \"$DSD_ID\"}},
    \"$DSD_ID\":      {\"displayName\": \"Data Store Decision\", \"nodeType\": \"DataStoreDecisionNode\",
                       \"x\": 330, \"y\": 140, \"connections\": {\"true\": \"$VERIFY_ID\", \"false\": \"$FAILURE_ID\"}},
    \"$VERIFY_ID\":   {\"displayName\": \"OATH Token Verifier\", \"nodeType\": \"OathTokenVerifierNode\",
                       \"x\": 560, \"y\": 60,  \"connections\": {\"successOutcome\": \"$SUCCESS_ID\",
                                                               \"failureOutcome\": \"$FAILURE_ID\",
                                                               \"notRegisteredOutcome\": \"$REGISTER_ID\"}},
    \"$REGISTER_ID\": {\"displayName\": \"OATH Registration\", \"nodeType\": \"OathRegistrationNode\",
                       \"x\": 560, \"y\": 240, \"connections\": {\"successOutcome\": \"$VERIFY_ID\",
                                                               \"failureOutcome\": \"$FAILURE_ID\"}}
  },
  \"staticNodes\": {
    \"startNode\":    {\"x\": 50,  \"y\": 25},
    \"$SUCCESS_ID\":  {\"x\": 820, \"y\": 60},
    \"$FAILURE_ID\":  {\"x\": 820, \"y\": 240}
  }
}"

for node in $OLD_COLLECTOR_NODES; do
  status=$(curl -s $CURL_OPTS -o /dev/null -w '%{http_code}' -X DELETE     -H "Accept-API-Version: resource=1.0"     -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR"     "$TREES_URL/nodes/$node")
  [ "$status" = "200" ] && echo "    removed old node $node"
done

echo
echo "Done. Tree '$TREE_NAME' is enabled in the root realm."
echo "Browser: https://$HOST_HDR/am/XUI/?realm=/&authIndexType=service&authIndexValue=$TREE_NAME"
echo "Next: bash mfa-otp-flow.sh   (scripted registration + login with computed TOTP codes)"
