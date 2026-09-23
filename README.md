# Ping Identity Platform (ForgeRock) — Local Kubernetes POC

Local POC of the Ping Identity Platform (AM, IDM, DS, login/admin UIs) via ForgeRock's
official **ForgeOps** deployment tooling, run on a local Kubernetes cluster (minikube).
This mirrors how the platform is actually deployed in production (Docker images + Helm
+ Kubernetes), which is the deployment model referenced in the IAM Engineer role JD.

Source: [ForgeOps 7.5 docs](https://docs.pingidentity.com/forgeops/7.5/) —
[Minikube prerequisites](https://docs.pingidentity.com/forgeops/7.5/setup/minikube.html),
[Helm-on-minikube deploy scenario](https://docs.pingidentity.com/forgeops/7.5/deploy/deploy-scenario-helm-local.html),
[Repositories](https://docs.pingidentity.com/forgeops/7.5/start/repositories.html).

## Why this shape

- **Kubernetes, not just Docker Compose** — the JD calls out "containerisation using
  Docker or Kubernetes" and "production-ready IAM infrastructure." ForgeOps' Helm chart
  is literally the production deployment path Ping customers use, so standing this up
  locally gives you talking points that map 1:1 to what the role expects.
- **AM + IDM + DS together** — the platform chart deploys all three, plus the
  login/admin UIs, so you get OAuth2/OIDC/SAML (AM), directory/LDAP (DS), and
  provisioning/reconciliation (IDM) in one place.

## Quick start (scripted)

Everything below (steps 1-7) is scripted for WSL2 Ubuntu:

```bash
# from Windows PowerShell, enter WSL2 first:
wsl -d Ubuntu-24.04
cd /mnt/c/Users/chamu/PoC

bash setup-wsl.sh   # installs kubectl/helm/kustomize/jq/minikube/kubens (idempotent)
bash deploy.sh       # clones forgeops, starts minikube, deploys the platform
bash teardown.sh     # tears down the deployment (add DELETE_CLUSTER=true to also delete minikube)
```

`setup-wsl.sh` will stop and tell you if Docker Desktop's WSL integration isn't
enabled yet for the distro — that one step is a GUI toggle (Docker Desktop ->
Settings -> Resources -> WSL Integration) it can't do for you.

The manual steps below are the same thing broken out, useful if you want to
understand/adjust what's happening or run it outside these scripts.

## 1. Prerequisites

Install on Windows via WSL2 or Docker Desktop's Linux containers (ForgeOps tooling
assumes a Bash environment — run these inside WSL2 Ubuntu, not native PowerShell):

| Tool | Version used in docs | Install |
|---|---|---|
| Docker | 26.1+ | Docker Desktop, with WSL2 integration enabled |
| kubectl | 1.30+ | `az`/`choco install kubernetes-cli` or via Docker Desktop |
| kubectx/kubens | 0.9+ | `choco install kubens` or brew/apt in WSL2 |
| kustomize | 5.4+ | `choco install kustomize` |
| helm | 3.15+ | `choco install kubernetes-helm` |
| jq | 1.7+ | `choco install jq` |
| minikube | 1.33+ | `choco install minikube` |
| Python 3 | 3.12+ | for ForgeOps helper scripts |

Minimum host resources for minikube: 4 CPU / 10GB RAM / 60GB disk free.

## 2. Get the ForgeOps repo

```bash
git clone https://github.com/ForgeRock/forgeops.git
cd forgeops
git checkout release/7.5-20251119
git checkout -b poc-local
```

## 3. Start the local cluster

```bash
minikube start --cpus=3 --memory=9g --disk-size=40g --cni=true \
  --kubernetes-version=stable \
  --addons=ingress,volumesnapshots,metrics-server \
  --driver=docker
```

## 4. Namespace + prerequisites (cert-manager, secret-agent, etc.)

```bash
kubectl create namespace poc
kubens poc

cd charts/scripts
./install-prereqs
```

## 5. Deploy the platform via Helm

Edit `charts/identity-platform/values.yaml` first if you want to pin a specific
`image.tag`. Then:

```bash
cd ../identity-platform

helm upgrade --install identity-platform \
  oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform \
  --version 7.5 --namespace poc \
  --set 'ds_idrepo.volumeClaimSpec.storageClassName=standard' \
  --set 'ds_cts.volumeClaimSpec.storageClassName=standard' \
  --set 'platform.ingress.hosts={poc.example.com}'
```

> Only single-instance deployments are supported on minikube — that's expected for a POC.

## 6. Watch it come up

```bash
kubectl get pods -w
```

Wait until every pod shows `Running`/`Completed` with all containers ready
(AM, IDM, DS-idrepo, DS-cts, login-ui, admin-ui, end-user-ui, ingress).

## 7. Access it

In a separate terminal, keep this running to expose the ingress:

```bash
minikube tunnel
```

Add a hosts entry (Windows: `C:\Windows\System32\drivers\etc\hosts`, run editor as
Administrator; if running minikube inside WSL2, also add it to WSL2's `/etc/hosts`
or use `minikube ip`):

```
127.0.0.1  poc.example.com
```

Then browse to:

- `https://poc.example.com/platform` — admin UI
- `https://poc.example.com/am` — AM console
- `https://poc.example.com/enduser` — end-user UI

Retrieve the generated `amadmin` password (secret-agent generates and stores it —
find it with):

```bash
kubectl get secrets -n poc | grep -i am
kubectl get secret <matching-secret-name> -n poc -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d
```

(Exact secret key name can shift between ForgeOps releases — `kubectl describe secret`
on the AM-related secret if the key above isn't present.)

## 8. Things worth practicing against this POC (mapped to the JD)

- **SSO/OIDC**: register an OAuth2/OIDC client in AM, run the authorization code flow
  against `/am/oauth2/...`.
- **SAML**: configure AM as an IdP, stand up a second AM realm or a SAML SP test app
  as the relying party.
- **MFA**: enable a WebAuthn or OTP module in an AM authentication tree.
- **LDAP/DS**: connect `ldapsearch`/Apache Directory Studio to the `ds-idrepo`
  service (`kubectl port-forward`) and inspect the identity repository.
- **IDM provisioning**: define a mapping/reconciliation between IDM and DS via the
  admin UI or `conf/sync.json`.
- **CI/CD**: this repo structure (Helm charts + Kustomize overlays under `forgeops/`)
  is exactly what you'd wire into a pipeline — practice scripting steps 3–6 as a
  `deploy.sh` or GitHub Actions job for handover documentation.

## 9. Tear down

```bash
helm uninstall identity-platform -n poc
minikube delete
```
