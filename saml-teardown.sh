#!/usr/bin/env bash
# Removes the SAML federation setup between AM (IdP) and the SimpleSAMLphp
# SP test app ("saml-sp"), so saml-setup.sh can rebuild it cleanly.
#
# Deliberately leaves AM's hosted IdP entity (https://poc.example.com/am)
# alone -- it's structurally valid and recreating a hosted SAML2 IDP via
# REST is high-risk. This only removes the parts that were hand-assembled
# and are safe/cheap to regenerate: the remote SP entity, the circle of
# trust, and the saml-sp app + its config.
#
# Usage: bash saml-teardown.sh
set -uo pipefail

NAMESPACE=poc
BASE_URL="${BASE_URL:-https://poc.example.com/am}"
HOST_HDR="${HOST_HDR:-poc.example.com}"
CURL_OPTS="${CURL_OPTS:--k}"
SP_ENTITY_ID="${SP_ENTITY_ID:-https://poc.example.com/simplesaml/module.php/saml/sp/metadata.php/default-sp}"
COT_ID="${COT_ID:-poc-cot}"

echo "==> Fetching amadmin password"
ADMIN_PW=$(kubectl get secret am-env-secrets -n "$NAMESPACE" -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)

echo "==> Authenticating as amadmin"
ADMIN_TOKEN=$(curl -s $CURL_OPTS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $ADMIN_PW" \
  -H "Host: $HOST_HDR" \
  "$BASE_URL/json/realms/root/authenticate" | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)

if [ -z "$ADMIN_TOKEN" ]; then
  echo "ERROR: failed to authenticate as amadmin."
  exit 1
fi
echo "    admin session ok"

SP_EID_B64=$(printf '%s' "$SP_ENTITY_ID" | base64 -w0 | tr '+/' '-_' | tr -d '=')

echo "==> 1/4 Deleting remote SP entity ($SP_ENTITY_ID)"
STATUS=$(curl -s $CURL_OPTS -o /tmp/saml_teardown_sp.json -w '%{http_code}' -X DELETE \
  -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR" -H "Accept-API-Version: resource=1.0" \
  "$BASE_URL/json/realms/root/realm-config/saml2/remote/$SP_EID_B64")
echo "    HTTP $STATUS $( [ "$STATUS" = "404" ] && echo '(already gone)')"

echo "==> 2/4 Deleting circle of trust ($COT_ID)"
STATUS=$(curl -s $CURL_OPTS -o /tmp/saml_teardown_cot.json -w '%{http_code}' -X DELETE \
  -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Host: $HOST_HDR" -H "Accept-API-Version: resource=1.0" \
  "$BASE_URL/json/realms/root/realm-config/federation/circlesoftrust/$COT_ID")
echo "    HTTP $STATUS $( [ "$STATUS" = "404" ] && echo '(already gone)')"

echo "==> 3/4 Deleting saml-sp k8s resources (deployment/service/ingress)"
kubectl delete -f saml-sp.yaml -n "$NAMESPACE" --ignore-not-found

echo "==> 4/4 Deleting sp-config ConfigMap"
kubectl delete configmap sp-config -n "$NAMESPACE" --ignore-not-found

echo
echo "Teardown complete. AM's hosted IdP entity was left untouched."
echo "Next: bash saml-setup.sh"
