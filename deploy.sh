#!/usr/bin/env bash
# End-to-end local deploy of the Ping Identity Platform (ForgeOps) on minikube.
# Run from WSL2 after setup-wsl.sh: bash deploy.sh
#
# This scripts README.md steps 2-6 so the whole POC stands up (or tears down and
# redeploys) from one command -- the kind of artifact worth showing in an IAM
# handover doc / CI job.
set -euo pipefail

NAMESPACE="${NAMESPACE:-poc}"
INGRESS_HOST="${INGRESS_HOST:-poc.example.com}"
FORGEOPS_BRANCH="${FORGEOPS_BRANCH:-release/7.5-20251119}"
FORGEOPS_DIR="${FORGEOPS_DIR:-$HOME/forgeops}"
CHART_VERSION="${CHART_VERSION:-7.5}"

echo "==> Namespace:      $NAMESPACE"
echo "==> Ingress host:   $INGRESS_HOST"
echo "==> ForgeOps branch: $FORGEOPS_BRANCH"
echo "==> ForgeOps dir:   $FORGEOPS_DIR"
echo

for c in docker kubectl kubens kustomize helm jq minikube; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not found. Run setup-wsl.sh first."; exit 1; }
done

echo "==> 1/6 Cloning/updating forgeops ($FORGEOPS_BRANCH)"
if [ -d "$FORGEOPS_DIR/.git" ]; then
  git -C "$FORGEOPS_DIR" fetch origin "$FORGEOPS_BRANCH"
  git -C "$FORGEOPS_DIR" checkout "$FORGEOPS_BRANCH"
  git -C "$FORGEOPS_DIR" pull origin "$FORGEOPS_BRANCH"
else
  git clone --branch "$FORGEOPS_BRANCH" https://github.com/ForgeRock/forgeops.git "$FORGEOPS_DIR"
fi

echo "==> 2/6 Starting minikube (skipped if already running)"
if ! minikube status >/dev/null 2>&1; then
  minikube start --cpus=3 --memory=9g --disk-size=40g --cni=true \
    --kubernetes-version=stable \
    --addons=ingress,volumesnapshots,metrics-server \
    --driver=docker
else
  echo "minikube already running"
fi

echo "==> 3/6 Namespace + prerequisites"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubens "$NAMESPACE"

( cd "$FORGEOPS_DIR/charts/scripts" && ./install-prereqs )

echo "==> 4/6 Helm deploy: identity-platform"
helm upgrade --install identity-platform \
  oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform \
  --version "$CHART_VERSION" --namespace "$NAMESPACE" --timeout 15m \
  --set "ds_idrepo.volumeClaimSpec.storageClassName=standard" \
  --set "ds_cts.volumeClaimSpec.storageClassName=standard" \
  --set "platform.ingress.hosts={$INGRESS_HOST}"

echo "==> 5/6 Waiting for pods to become ready (this can take several minutes)"
kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout=900s || {
  echo "Some pods are not Ready yet -- check 'kubectl get pods -n $NAMESPACE' manually."
}
kubectl get pods -n "$NAMESPACE"

echo "==> 6/6 Done."
echo
echo "Next steps:"
echo "  1. In another terminal: minikube tunnel"
echo "  2. Add to hosts file: 127.0.0.1  $INGRESS_HOST"
echo "     (Windows: C:\\Windows\\System32\\drivers\\etc\\hosts, run editor as Administrator)"
echo "  3. Browse: https://$INGRESS_HOST/platform"
echo "  4. amadmin password: kubectl get secrets -n $NAMESPACE | grep -i am"
echo "     then: kubectl get secret <name> -n $NAMESPACE -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d"
