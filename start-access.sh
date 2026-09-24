#!/usr/bin/env bash
# Brings up everything needed to reach the already-deployed POC from a browser:
#   1. Starts Docker Desktop if it isn't reachable yet (debounced check -- see
#      INSTALLATION.md §4.1, a single successful `docker version` isn't trusted)
#   2. Checks minikube status, starts the cluster if it's not running
#   3. Recreates the AM pod if it is stuck on "Can't open boot keystore". After a
#      node/Docker restart the openam container restarts inside the same pod,
#      its emptyDir home survives, and the image's non-idempotent entrypoint
#      (`mkdir .../keystores/boot`) leaves AM unable to boot. A fresh pod gets a
#      clean emptyDir. OAuth2 clients / SAML entities live in DS and survive;
#      auth trees do NOT (see step 4).
#   4. Recreates the PocMFA auth tree if it's missing. Trees are file-based
#      config in AM's emptyDir, so ANY new AM pod (step 3, eviction, rollout
#      restart) starts without it. Runs mfa-setup-tree.sh through a short-lived
#      port-forward to svc/am, so it doesn't depend on steps 5/6.
#   5. Starts `kubectl port-forward` for ingress-nginx on host 80/443 (used by
#      the SAML flow scripts -- see saml-sso-flow.sh)
#   6. Starts `minikube tunnel` (used for general browser access -- see README.md)
#
# Steps 5+6 both expose the ingress and can conflict on ports 80/443 if left
# running together long-term; both are started here because both are used
# elsewhere in this repo, but SKIP_PORT_FORWARD=true or SKIP_TUNNEL=true will
# leave one out if you hit a bind conflict.
#
# Run from WSL2: bash start-access.sh
# Stop the background jobs: pkill -f 'kubectl port-forward -n ingress-nginx'
#                            pkill -f 'minikube tunnel'
set -uo pipefail

NAMESPACE="${NAMESPACE:-poc}"
LOG_DIR="${LOG_DIR:-/tmp/poc-logs}"
SKIP_PORT_FORWARD="${SKIP_PORT_FORWARD:-false}"
SKIP_TUNNEL="${SKIP_TUNNEL:-false}"
AM_WAIT="${AM_WAIT:-300}"
SKIP_TREES="${SKIP_TREES:-false}"
MFA_TREE="${MFA_TREE:-PocMFA}"
AM_PF_PORT="${AM_PF_PORT:-18090}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AM_READY=false
mkdir -p "$LOG_DIR"

echo "==> 1/6 Checking Docker"
if ! docker version >/dev/null 2>&1; then
  echo "    docker not reachable -- launching Docker Desktop"
  powershell.exe -Command "Start-Process 'Docker Desktop'" >/dev/null 2>&1 &

  echo "    waiting for a stable connection (3 consecutive checks, 5s apart, 3min timeout)"
  ELAPSED=0
  CONSECUTIVE=0
  while [ "$CONSECUTIVE" -lt 3 ]; do
    if [ "$ELAPSED" -ge 180 ]; then
      echo "ERROR: Docker did not come up within 3 minutes."
      echo "Open Docker Desktop -> Settings -> Resources -> WSL Integration,"
      echo "enable it for this distro, click Apply & Restart, then re-run this script."
      exit 1
    fi
    if docker version >/dev/null 2>&1; then
      CONSECUTIVE=$((CONSECUTIVE + 1))
    else
      CONSECUTIVE=0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
fi
echo "    docker OK: $(docker --version)"

echo "==> 2/6 Checking minikube"
if minikube status >/dev/null 2>&1; then
  echo "    minikube already running"
else
  echo "    starting minikube"
  minikube start --cpus=3 --memory=9g --disk-size=40g --cni=true \
    --kubernetes-version=stable \
    --addons=ingress,volumesnapshots,metrics-server \
    --driver=docker
fi

echo "==> 3/6 Checking AM pod (waits up to ${AM_WAIT}s for readiness)"
ELAPSED=0
while true; do
  AM_POD=$(kubectl get pods -n "$NAMESPACE" -l app=am -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$AM_POD" ]; then
    echo "    no AM pod found in namespace $NAMESPACE -- skipping"
    break
  fi
  READY=$(kubectl get pod "$AM_POD" -n "$NAMESPACE"     -o jsonpath='{.status.containerStatuses[?(@.name=="openam")].ready}' 2>/dev/null)
  if [ "$READY" = "true" ]; then
    echo "    $AM_POD ready"
    AM_READY=true
    break
  fi
  if kubectl logs "$AM_POD" -n "$NAMESPACE" -c openam 2>/dev/null | grep -q "Can't open boot keystore"; then
    echo "    $AM_POD stuck on stale boot keystore -- recreating pod"
    kubectl delete pod "$AM_POD" -n "$NAMESPACE" --wait=true
    if kubectl rollout status deploy/am -n "$NAMESPACE" --timeout=420s; then
      echo "    AM ready"
      AM_READY=true
    else
      echo "    WARNING: new AM pod not ready -- check: kubectl logs -n $NAMESPACE deploy/am -c openam"
    fi
    break
  fi
  if [ "$ELAPSED" -ge "$AM_WAIT" ]; then
    echo "    WARNING: $AM_POD not ready after ${AM_WAIT}s and no known cause in its logs"
    echo "    check: kubectl logs -n $NAMESPACE $AM_POD -c openam"
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "==> 4/6 Checking auth tree '$MFA_TREE'"
if [ "$SKIP_TREES" = "true" ]; then
  echo "    skipped (SKIP_TREES=true)"
elif [ "$AM_READY" != "true" ]; then
  echo "    skipped -- AM not ready"
else
  kubectl port-forward -n "$NAMESPACE" svc/am "$AM_PF_PORT:80" > "$LOG_DIR/am-tree-pf.log" 2>&1 &
  PF_PID=$!
  AM_URL="http://localhost:$AM_PF_PORT/am"
  for _ in $(seq 1 15); do
    curl -s -o /dev/null -m 2 "$AM_URL/json/health/live" && break
    sleep 1
  done
  ADMIN_PW=$(kubectl get secret am-env-secrets -n "$NAMESPACE" -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)
  ADMIN_TOKEN=$(curl -s -m 10 -X POST -H 'Content-Type: application/json'     -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $ADMIN_PW"     -H "Accept-API-Version: resource=2.0, protocol=1.0" -H "Host: poc.example.com"     "$AM_URL/json/realms/root/authenticate" | grep -oE '"tokenId":"[^"]+"' | cut -d'"' -f4)
  if [ -z "$ADMIN_TOKEN" ]; then
    echo "    WARNING: couldn't authenticate as amadmin via port-forward -- run bash mfa-setup-tree.sh later"
  else
    TREE_STATUS=$(curl -s -m 10 -o /dev/null -w '%{http_code}'       -H "iPlanetDirectoryPro: $ADMIN_TOKEN" -H "Accept-API-Version: resource=1.0" -H "Host: poc.example.com"       "$AM_URL/json/realms/root/realm-config/authentication/authenticationtrees/trees/$MFA_TREE")
    if [ "$TREE_STATUS" = "200" ]; then
      echo "    present"
    else
      echo "    missing (HTTP $TREE_STATUS) -- AM pod was recreated; running mfa-setup-tree.sh"
      if BASE_URL="$AM_URL" TREE_NAME="$MFA_TREE" bash "$SCRIPT_DIR/mfa-setup-tree.sh" > "$LOG_DIR/mfa-setup-tree.log" 2>&1; then
        echo "    recreated (log: $LOG_DIR/mfa-setup-tree.log)"
      else
        echo "    WARNING: mfa-setup-tree.sh failed -- see $LOG_DIR/mfa-setup-tree.log"
      fi
    fi
  fi
  kill "$PF_PID" 2>/dev/null
  wait "$PF_PID" 2>/dev/null
fi

NEED_SUDO=false
[ "$SKIP_PORT_FORWARD" != "true" ] && NEED_SUDO=true
if [ "$NEED_SUDO" = "true" ]; then
  echo "==> caching sudo credentials (port-forward binds host ports 80/443; minikube tunnel elevates internally)"
  sudo -v
  ( while true; do sudo -n true; sleep 60; done ) &
  disown
fi

echo "==> 5/6 Ingress port-forward (host 80/443 -> svc/ingress-nginx-controller)"
if [ "$SKIP_PORT_FORWARD" = "true" ]; then
  echo "    skipped (SKIP_PORT_FORWARD=true)"
elif pgrep -f "kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller" >/dev/null; then
  echo "    already running"
else
  nohup sudo -E kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 443:443 80:80 \
    > "$LOG_DIR/port-forward.log" 2>&1 &
  disown
  echo "    started (log: $LOG_DIR/port-forward.log)"
fi

echo "==> 6/6 minikube tunnel"
if [ "$SKIP_TUNNEL" = "true" ]; then
  echo "    skipped (SKIP_TUNNEL=true)"
elif pgrep -f "minikube tunnel" >/dev/null; then
  echo "    already running"
else
  nohup minikube tunnel > "$LOG_DIR/minikube-tunnel.log" 2>&1 &
  disown
  echo "    started (log: $LOG_DIR/minikube-tunnel.log)"
fi

echo
echo "Done. Browse: https://poc.example.com/platform (hosts entry required -- see README.md)"
echo "Logs: $LOG_DIR/"
echo "Stop: pkill -f 'kubectl port-forward -n ingress-nginx'; pkill -f 'minikube tunnel'"
