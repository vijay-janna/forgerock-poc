#!/usr/bin/env bash
# CI checks for this repo -- run by .github/workflows/ci.yml on every push/PR,
# and runnable locally before pushing (same script, same result):
#   1. shellcheck on every tracked *.sh (fails on warnings/errors, not style notes)
#   2. helm template: render the identity-platform chart with values-poc.yaml
#   3. kubeconform: schema-validate the rendered manifests + saml-sp.yaml
#      (ForgeOps/cert-manager CRDs have no bundled schema -> skipped, not failed)
#   4. Policy assertions on the rendered output -- the fixes this POC depends on
#      (INSTALLATION.md §4) must not silently regress:
#        - ds-idrepo memory limit 2Gi (§4.7)
#        - DS volume claims on the "standard" storage class (minikube)
#        - ingress host poc.example.com
#
# No cluster needed: nothing here talks to Kubernetes.
# Requires: shellcheck, helm (>=3.8, OCI), kubeconform, yq (mikefarah v4)
#
# Usage: bash ci-validate.sh
# Env overrides: CHART_VERSION (7.5), VALUES_FILE (values-poc.yaml), OUT_DIR
set -uo pipefail

cd "$(dirname "$0")" || exit 2
CHART="oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform"
CHART_VERSION="${CHART_VERSION:-7.5}"
VALUES_FILE="${VALUES_FILE:-values-poc.yaml}"
OUT_DIR="${OUT_DIR:-$(mktemp -d)}"
mkdir -p "$OUT_DIR"
RENDERED="$OUT_DIR/identity-platform.yaml"
FAILED=0

pass() { echo "    PASS: $1"; }
fail() { echo "    FAIL: $1"; FAILED=1; }

for t in shellcheck helm kubeconform yq; do
  command -v "$t" >/dev/null || { echo "ERROR: '$t' not found in PATH"; exit 2; }
done

echo "==> 1/4 shellcheck"
mapfile -t SCRIPTS < <(git ls-files '*.sh')
if shellcheck -x -S warning "${SCRIPTS[@]}"; then
  pass "${#SCRIPTS[@]} scripts"
else
  fail "shellcheck reported warnings/errors (above)"
fi

echo "==> 2/4 helm template ($CHART $CHART_VERSION, -f $VALUES_FILE)"
if helm template identity-platform "$CHART" --version "$CHART_VERSION" --namespace poc \
     -f "$VALUES_FILE" > "$RENDERED" 2> "$OUT_DIR/helm.err"; then
  pass "rendered $(grep -c '^kind:' "$RENDERED") resources -> $RENDERED"
else
  cat "$OUT_DIR/helm.err"
  fail "helm template failed"
  echo; echo "RESULT: FAILED"; exit 1
fi

echo "==> 3/4 kubeconform (schema validation)"
if kubeconform -strict -ignore-missing-schemas -summary "$RENDERED" saml-sp.yaml; then
  pass "manifests valid"
else
  fail "schema validation errors (above)"
fi

echo "==> 4/4 Policy assertions"
# assert <description> <yq expression over the rendered stream> <expected>
assert() {
  local got
  got=$(yq ea "$2" "$RENDERED" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  if [ "$got" = "$3" ]; then pass "$1 ($got)"; else fail "$1: expected '$3', got '${got:-<nothing>}'"; fi
}
assert "ds-idrepo memory limit" \
  'select(.kind == "StatefulSet" and .metadata.name == "ds-idrepo") | .spec.template.spec.containers[] | select(.name == "ds") | .resources.limits.memory' \
  "2Gi"
assert "ds-idrepo memory request" \
  'select(.kind == "StatefulSet" and .metadata.name == "ds-idrepo") | .spec.template.spec.containers[] | select(.name == "ds") | .resources.requests.memory' \
  "2Gi"
assert "DS volume claims use storage class 'standard'" \
  '[select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[].spec.storageClassName] | unique | .[]' \
  "standard"
assert "ingress host" \
  '[select(.kind == "Ingress") | .spec.rules[].host] | unique | .[]' \
  "poc.example.com"

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: FAILED"; fi
exit "$FAILED"
