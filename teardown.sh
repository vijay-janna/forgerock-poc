#!/usr/bin/env bash
# Tears down the POC deployment. Run from WSL2: bash teardown.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-poc}"
DELETE_CLUSTER="${DELETE_CLUSTER:-false}"

helm uninstall identity-platform -n "$NAMESPACE" || true
kubectl delete namespace "$NAMESPACE" --ignore-not-found

if [ "$DELETE_CLUSTER" = "true" ]; then
  minikube delete
else
  echo "minikube cluster left running (set DELETE_CLUSTER=true to also delete it)"
fi
