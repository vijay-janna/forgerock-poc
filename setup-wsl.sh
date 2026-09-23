#!/usr/bin/env bash
# One-time install of ForgeOps CLI prerequisites inside WSL2 (Ubuntu).
# Run from WSL2: bash setup-wsl.sh
# Docker itself is NOT installed here — it must come from Docker Desktop's
# WSL integration (Settings > Resources > WSL Integration > enable for this distro).
set -euo pipefail

echo "==> Checking Docker Desktop WSL integration"
if ! command -v docker >/dev/null 2>&1 || ! docker version >/dev/null 2>&1; then
  echo "ERROR: 'docker' is not usable from this WSL distro."
  echo "Open Docker Desktop -> Settings -> Resources -> WSL Integration,"
  echo "enable it for this distro, click Apply & Restart, then re-run this script."
  exit 1
fi
echo "docker OK: $(docker --version)"

echo "==> apt packages: jq, python3-venv, ca-certificates, curl"
sudo apt-get update -y
sudo apt-get install -y jq curl ca-certificates python3-venv

install_kubectl() {
  command -v kubectl >/dev/null 2>&1 && { echo "kubectl already installed"; return; }
  echo "==> Installing kubectl"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/kubectl
}

install_kubectx_kubens() {
  command -v kubens >/dev/null 2>&1 && { echo "kubens already installed"; return; }
  echo "==> Installing kubectx/kubens"
  sudo git clone --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx 2>/dev/null || \
    (cd /opt/kubectx && sudo git pull)
  sudo ln -sf /opt/kubectx/kubectx /usr/local/bin/kubectx
  sudo ln -sf /opt/kubectx/kubens /usr/local/bin/kubens
}

install_kustomize() {
  command -v kustomize >/dev/null 2>&1 && { echo "kustomize already installed"; return; }
  echo "==> Installing kustomize"
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash -s -- /tmp
  sudo mv /tmp/kustomize /usr/local/bin/kustomize
}

install_helm() {
  command -v helm >/dev/null 2>&1 && { echo "helm already installed"; return; }
  echo "==> Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_minikube() {
  command -v minikube >/dev/null 2>&1 && { echo "minikube already installed"; return; }
  echo "==> Installing minikube"
  curl -fsSLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  chmod +x /tmp/minikube
  sudo mv /tmp/minikube /usr/local/bin/minikube
}

install_kubectl
install_kubectx_kubens
install_kustomize
install_helm
install_minikube

echo
echo "==> Versions installed:"
for c in docker kubectl kubens kustomize helm jq minikube; do
  printf "%-10s %s\n" "$c" "$($c version --short 2>/dev/null || $c --version 2>/dev/null | head -1)"
done

echo
echo "Done. Next: bash deploy.sh"
