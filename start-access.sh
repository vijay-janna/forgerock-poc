#!/usr/bin/env bash
# Brings up everything needed to reach the already-deployed POC from a browser:
#   1. Starts Docker Desktop if it isn't reachable yet (debounced check -- see
#      INSTALLATION.md §4.1, a single successful `docker version` isn't trusted)
#   2. Checks minikube status, starts the cluster if it's not running
#   3. Starts `kubectl port-forward` for ingress-nginx on host 80/443 (used by
#      the SAML flow scripts -- see saml-sso-flow.sh)
#   4. Starts `minikube tunnel` (used for general browser access -- see README.md)
#
# Steps 3+4 both expose the ingress and can conflict on ports 80/443 if left
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
mkdir -p "$LOG_DIR"

echo "==> 1/4 Checking Docker"
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

echo "==> 2/4 Checking minikube"
if minikube status >/dev/null 2>&1; then
  echo "    minikube already running"
else
  echo "    starting minikube"
  minikube start --cpus=3 --memory=9g --disk-size=40g --cni=true \
    --kubernetes-version=stable \
    --addons=ingress,volumesnapshots,metrics-server \
    --driver=docker
fi

NEED_SUDO=false
[ "$SKIP_PORT_FORWARD" != "true" ] && NEED_SUDO=true
if [ "$NEED_SUDO" = "true" ]; then
  echo "==> caching sudo credentials (port-forward binds host ports 80/443; minikube tunnel elevates internally)"
  sudo -v
  ( while true; do sudo -n true; sleep 60; done ) &
  disown
fi

echo "==> 3/4 Ingress port-forward (host 80/443 -> svc/ingress-nginx-controller)"
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

echo "==> 4/4 minikube tunnel"
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
