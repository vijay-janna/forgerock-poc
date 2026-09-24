# Ping Identity Platform (ForgeRock) — Local POC Installation & Runbook

Target audience: engineering handover / self-reference. Documents the full install of
the Ping Identity Platform (AM, IDM, DS, login/admin UIs) via ForgeOps on a local
Kubernetes cluster (minikube, WSL2, Windows), including every issue hit during the
build and how each was diagnosed and fixed.

- Environment: Windows 11 + WSL2 (Ubuntu-24.04) + Docker Desktop + minikube
- Deployment method: ForgeOps Helm chart (`identity-platform`), release branch
  `release/7.5-20251119`
- Repo: [github.com/ForgeRock/forgeops](https://github.com/ForgeRock/forgeops)

---

## 1. Architecture

| Component | Role |
|---|---|
| AM | Access Management — SSO, OAuth2/OIDC, SAML, MFA |
| IDM | Identity Management — provisioning, reconciliation |
| DS (ds-idrepo) | Directory Service — identity repository |
| DS (ds-cts) | Directory Service — Core Token Service (sessions/tokens) |
| login-ui / admin-ui / end-user-ui | Platform UIs |
| amster | Post-install Job — imports AM configuration (realms, auth trees, stores) |
| secret-agent | Operator — generates and manages all platform secrets/certs |
| cert-manager | Operator — issues TLS certs used by ingress/webhooks |

All components deploy into one Kubernetes namespace (`poc`) via a single Helm chart.

---

## 2. Prerequisites

| Tool | Purpose |
|---|---|
| Docker Desktop (WSL2 backend, WSL integration enabled for the distro) | Container runtime |
| WSL2 (Ubuntu) | Linux environment for the Bash-based tooling |
| kubectl, helm, kustomize, jq, minikube, kubens | Cluster tooling |

Minimum host resources: 4 CPU / 20GB RAM (the minikube node alone gets 14GB) / 60GB disk free.

Scripted install of the CLI tools: [setup-wsl.sh](setup-wsl.sh).

---

## 3. Installation steps (as executed)

```bash
wsl -d Ubuntu-24.04
cd /mnt/c/Users/chamu/PoC

bash setup-wsl.sh   # installs kubectl/helm/kustomize/jq/minikube/kubens
bash deploy.sh       # clones forgeops, starts minikube, deploys the platform via Helm
```

`deploy.sh` automates:
1. Clone/update `forgeops` at `release/7.5-20251119`
2. Start minikube (`--cpus=3 --memory=14g --disk-size=40g`, ingress/volumesnapshots/metrics-server addons)
3. Create the `poc` namespace, install prerequisites (secret-agent, cert-manager, NGINX ingress)
4. `helm upgrade --install identity-platform oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform --version 7.5 --timeout 15m`
5. Wait for all pods to become Ready

### 3.1 Final access steps (manual — require privileges the automation doesn't have)

**Add the hosts entry** (requires Administrator):
- Open Notepad as Administrator
- Edit `C:\Windows\System32\drivers\etc\hosts`, add:
  ```
  127.0.0.1  poc.example.com
  ```

**Start the ingress tunnel** (requires an interactive sudo password, entered when
minikube prompts for it — do **not** prefix the whole command with `sudo`; run as
root, minikube looks for its profile under `/root/.minikube` instead of your own
`~/.minikube` and fails with `Profile "minikube" not found`):
```bash
minikube tunnel
```
minikube will prompt for your password itself when it needs to configure routing.
Leave this running in its own terminal — it's what routes `poc.example.com` traffic
into the cluster's ingress controller.

**Browse to:**
```
https://poc.example.com/platform
```

**Retrieve the `amadmin` password** (don't hardcode it in documentation — pull it live):
```bash
kubectl get secret am-env-secrets -n poc -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d
```

---

## 4. Diagnostic runbook — issues hit during this build

This POC did not come up cleanly on the first attempt. Each issue below was
diagnosed from cluster/pod evidence (not guessed), documented here in the order
encountered.

### 4.1 Docker Desktop WSL2 integration not usable after enabling

**Symptom:** `setup-wsl.sh` reported `docker OK`, but a subsequent `deploy.sh` run
failed immediately with `kubectl: not found`, then `docker: not found`.

**Diagnosis:**
- `command -v kubectl` succeeded because `/usr/local/bin/kubectl` was a symlink into
  `/mnt/wsl/docker-desktop/cli-tools/...` — but that mount only exists while Docker
  Desktop's WSL2 backend distro is actually running. It had dropped after being
  toggled on.
- Confirmed via `wsl -l -v`: the `docker-desktop` backend distro was `Stopped`.

**Fix:**
1. `wsl --shutdown` (from Windows) to force a clean restart of all WSL distros.
2. Fully restart Docker Desktop (`Stop-Process -Name "Docker Desktop" -Force`, then
   relaunch `Docker Desktop.exe`) — a `wsl --shutdown` alone left Docker Desktop's
   Windows-side service in a stale state that didn't reconnect.
3. Verified with a **debounced** poll (3 consecutive successful `docker version`
   calls, 5s apart) rather than a single check — the connection flickered briefly
   during Docker Desktop's own restart, and a single-check poll caught a false
   positive.

**Lesson:** after any Docker Desktop WSL-integration change, don't trust the first
successful `docker version` — verify it's stable, not just momentarily up.

### 4.2 `secret-agent` operator stuck in `ErrImagePull`

**Symptom:** `helm upgrade --install` failed immediately:
```
failed calling webhook "msecretagentconfiguration.kb.io": ... connection refused
```

**Diagnosis:** `kubectl describe pod -n secret-agent` showed the operator's sidecar
container stuck:
```
Failed to pull image "gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0": ... not found
```
`gcr.io/kubebuilder/kube-rbac-proxy` was sunset upstream; the pinned tag in this
chart version no longer resolves. Confirmed via `docker manifest inspect` that
`quay.io/brancz/kube-rbac-proxy:v0.18.1` (the image kubebuilder's proxy mirrored)
still exists and pulls successfully.

**Fix:**
```bash
kubectl set image deployment/secret-agent \
  secret-agent-kube-rbac-proxy=quay.io/brancz/kube-rbac-proxy:v0.18.1 \
  -n secret-agent
kubectl rollout status deployment/secret-agent -n secret-agent
```
Waited for the `secret-agent` Service to have a ready endpoint before retrying Helm.

### 4.3 Concurrent `deploy.sh` runs collided

**Symptom:** `Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is
in progress`.

**Cause:** `deploy.sh` was run once from an automated/background terminal and once
manually at the same time — Helm's release lock (a Secret) rejected the second
caller. The first run then failed on its own with a post-upgrade hook timeout
because the DS StatefulSet pods got recreated mid-flight by the overlapping runs.

**Lesson:** never run `deploy.sh` (or any `helm`/`kubectl` mutating command) from two
terminals against the same release at once. Treat it as a single-writer operation.

### 4.4 Default Helm hook timeout too short for first boot

**Symptom:** `Upgrade "identity-platform" failed: post-upgrade hooks failed: ...
timed out waiting for the condition`, even though pods were still healthily
starting.

**Cause:** AM/IDM/DS take several minutes to pass their startup probes on first
boot; Helm's default 5-minute timeout expired while the `amster` config Job was
still legitimately waiting on AM.

**Fix:** added `--timeout 15m` to the `helm upgrade --install` command in
[deploy.sh](deploy.sh).

### 4.5 AM stuck failing to bind to DS-CTS (`Invalid Credentials`)

This was the deepest issue and took several diagnostic passes.

**Symptom:** AM pods stayed `0/1 Ready` indefinitely. `health/live` returned `200`
(AM itself was up) but `health/ready` returned `503`. AM logs repeated:
```
Unable to start persistent search against [ldaps://ds-cts-0.ds-cts:1636]
for baseDN ou=tokens: Unable to retrieve a connection
```

**Diagnosis path:**
1. First hypothesis — stale JVM DNS cache pointing at a dead DS pod IP (DS pods had
   been recreated once by the concurrent-run collision in §4.3). Deleted the AM
   pods to force fresh DNS resolution. **Did not fix it** — same error on the new
   pods.
2. Checked DS's own logs directly (`kubectl logs ds-cts-0`) and found the real
   cause: DS was rejecting the bind with
   `"The password provided by the user did not match any password(s) stored in the
   user's entry"` — a genuine credential mismatch, not a connectivity problem.
3. Verified by extracting the current secret value and testing it directly:
   ```bash
   PW=$(kubectl get secret ds-env-secrets -n poc -o jsonpath='{.data.AM_STORES_CTS_PASSWORD}' | base64 -d)
   kubectl exec ds-cts-0 -n poc -c ds -- /opt/opendj/bin/ldapsearch --useSsl --trustAll \
     --bindDN "uid=openam_cts,ou=admins,ou=famrecords,ou=openam-session,ou=tokens" \
     --bindPassword "$PW" --baseDN "ou=tokens" --searchScope base "(objectclass=*)" dn
   ```
   Confirmed AM's env var matched the current secret exactly, and the direct LDAP
   bind with that exact value still failed against DS — proving DS's stored
   directory password and the current secret had diverged.
4. Wiped DS's PVCs for a full re-bootstrap against the current secret. **Still
   failed** — same error, ruling out stale PVC data as the cause.
5. Inspected DS's init container logs and traced the actual mechanism: DS's own
   bootstrap only creates the CTS backend schema/structure — the `uid=openam_cts`
   account's working password is reconciled separately by the `amster` post-install
   Job. That Job had been deleted as part of an earlier cleanup attempt and never
   re-ran, so the reconciliation step never happened.
6. Re-triggering `amster` (via a fresh `helm upgrade`) exposed a circular
   dependency: `amster`'s init container polls `http://am:80/am/json/health/ready`
   through the AM **Service** — which has zero endpoints while AM is not Ready,
   which it can't be while CTS auth is broken. This is not normally a deadlock in
   an untouched deployment; it only became one because of the manual interventions
   already made (see below).

**Root cause:** the very first Helm install attempt failed while `secret-agent`'s
webhook was still down (§4.2), which likely left the `SecretAgentConfiguration`
partially processed. Combined with the concurrent-run collision (§4.3) and a
manual `amster` Job deletion during troubleshooting, the secret and DS directory
state diverged in a way that a normal single clean deployment does not hit.

**Fix:** rather than continue patching individual symptoms, did a full clean reset:
```bash
helm uninstall identity-platform -n poc
kubectl delete namespace poc --wait=true
```
then a single, uninterrupted `bash deploy.sh` run. This deployed successfully on
the first attempt — `helm` reported `STATUS: deployed`, `amster` completed, and all
pods reached `1/1 Running`.

**Lesson:** once secret/state consistency is in question after multiple manual
interventions on a secret-managed system (secret-agent, in this case), don't keep
chasing individual symptoms — a full teardown and single clean redeploy is faster
and more reliable than trying to reconcile drifted state by hand.

### 4.6 `sudo minikube tunnel` fails with "Profile not found"

**Symptom:**
```
$ sudo minikube tunnel
🤷  Profile "minikube" not found. Run "minikube profile list" to view all profiles.
```

**Cause:** minikube stores cluster profile state under the invoking user's home
directory (`~/.minikube`). Prefixing the whole command with `sudo` runs it as
`root`, which looks under `/root/.minikube` instead — a different, empty location —
so it can't find the already-running cluster.

**Fix:** run `minikube tunnel` as your normal user, with no `sudo` prefix. minikube
elevates internally and prompts for the sudo password itself only when it actually
needs to configure a network route.

### 4.7 `ds-idrepo` OOMKilled after an hour or two of use

**Symptom:** `ds-idrepo-0` shows restarts. `kubectl get pod ds-idrepo-0 -o json`
has `lastState.terminated.reason: OOMKilled` (exit code 137). While DS restarts, AM
and IDM lose their directory.

**Cause:** the chart's default limit is `1366Mi`, and the DS image starts the JVM
with `-XX:MaxRAMPercentage=75`, so the heap alone can take ~1 GiB. Once heap and
non-heap memory (metaspace, threads, buffers) are both in use, the container
exceeds its limit.

**Fix:** raised ds-idrepo to `2Gi` (request and limit). Live:
```bash
kubectl patch sts ds-idrepo -n poc --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"limits":{"memory":"2Gi"},"requests":{"cpu":"500m","memory":"2Gi"}}}]'
```
and permanently in [deploy.sh](deploy.sh) (`--set ds_idrepo.resources...`). A
`kubectl patch` rather than `helm upgrade` avoids re-running the `amster`
config-import hook.

**Follow-on:** with DS at 2Gi, the original 9g minikube node ran at 99% memory
and ~750% CPU, and the Kubernetes API server stopped answering (`kubectl`:
`TLS handshake timeout`). The node now gets 14g. New clusters get it from
`deploy.sh`/`start-access.sh` (`MINIKUBE_MEMORY`). For an existing cluster,
`start-access.sh` raises the container limit in place (`docker update --memory
14g --memory-swap 14g minikube`, no restart needed).

### 4.8 AM stuck on "Can't open boot keystore" after a node restart

**Symptom:** after Docker Desktop/minikube restarts, `am` shows `0/1 Running`.
The startup probe gets HTTP 500, and the logs show `Can't open boot keystore`,
then `Configuration store is not available` on every request.

**Cause:** the openam container restarts inside the *same* pod, so its `emptyDir`
home survives. The image's entrypoint isn't idempotent (`mkdir
.../keystores/boot` fails with "File exists"), which leaves AM unable to read its
boot keystore.

**Fix:** `kubectl delete pod -n poc -l app=am`. The new pod gets a clean
`emptyDir`. [start-access.sh](start-access.sh) (step 3) now does this
automatically. It then recreates the `PocMFA` tree (step 4), because auth
trees live in that `emptyDir` too.

---

## 5. OAuth2/OIDC REST API gotchas (found while building the demo scripts)

Building [oidc-setup-client.sh](oidc-setup-client.sh) and
[oidc-auth-code-flow.sh](oidc-auth-code-flow.sh) surfaced three AM REST behaviors
worth knowing before scripting against it in production:

1. **`POST .../users?_action=create` does not enforce username uniqueness.**
   Running it twice for the same username silently created two separate directory
   entries both matching that username, which then made authentication
   deterministically fail (`401 Authentication Failed`) with no indication *why* —
   the ambiguity is only visible by querying `_queryFilter=true` and noticing
   `resultCount:2`. Fix: always query-then-create for identities, never assume
   the create call is idempotent.
2. **`PUT` on an OAuth2Client is a full-replace, not a safe upsert.** The first
   `PUT` (create) causes AM to auto-populate advanced config — including the ID
   token signing algorithm — as explicit non-inherited values. A second `PUT`
   with the same minimal payload against an *existing* client doesn't repopulate
   those defaults, and the client silently breaks: the authorize step still
   succeeds, but token exchange fails with `{"error":"invalid_request",
   "error_description":"Unknown Signing Algorithm"}`. Fix: check existence first
   (`GET` the client) and only `PUT`-create when it's genuinely absent; treat
   config changes to an existing client as a deliberate, separate action.
3. **Don't create end users through AM's `/json/.../users?_action=create` at all.
   Create them through IDM (`POST /openidm/managed/user?_action=create`).** AM writes
   a bare LDAP entry. It's missing IDM's `fr-idm-managed-user-hybrid-obj` objectClass
   and its `fr-idm-managed-user-meta` record, so IDM queries never return the user.
   Symptoms: the platform `Login` tree fails after the password check ("No object to
   increment" / "Login count is not supported for this object"), and the end-user
   UI (`/enduser`) shows an empty dashboard because every `/openidm` call returns
   503. Both scripts now create users via IDM (shared helper
   [lib-idm-user.sh](lib-idm-user.sh), which authenticates as AM's
   `idm-provisioning` client). A user created the old way is detected and
   recreated with the same username/password and a new `fr-idm-uuid`. The IDM
   password policy rejects passwords that contain the userName, givenName or sn.

Also note: AM validates the incoming request's `Host` header against its
configured FQDN — REST calls made against `localhost` (e.g. via
`kubectl port-forward`) need an explicit `Host: poc.example.com` header or AM
returns `{"message":"Realm not found"}` / `"FQDN ... is not valid"`. Calls made
against the real `https://poc.example.com` ingress URL don't need this, since the
Host header is already correct.

---

## 6. Verification

```bash
kubectl get pods -n poc
```
Expected end state:
```
NAME                          READY   STATUS
admin-ui-...                  1/1     Running
am-...                        1/1     Running
amster-...                    0/1     Completed   # Job — Completed is correct, not Ready
ds-cts-0                      1/1     Running
ds-idrepo-0                   1/1     Running
end-user-ui-...                1/1     Running
idm-...                       1/1     Running
login-ui-...                  1/1     Running
```

`helm status identity-platform -n poc` should show `STATUS: deployed`.

---

## 7. Teardown

```bash
bash teardown.sh                 # removes the Helm release + namespace
DELETE_CLUSTER=true bash teardown.sh   # also deletes the minikube cluster
```

---

## 8. Things worth practicing further against this POC

- **SSO/OIDC**: [oidc-setup-client.sh](oidc-setup-client.sh) registers a confidential
  OAuth2/OIDC client and a demo user in AM via REST; [oidc-auth-code-flow.sh](oidc-auth-code-flow.sh)
  drives a full authorization code flow end-to-end (login → `/authorize` → code →
  `/access_token` → `/userinfo`) with `curl`, no browser needed. See §5 for gotchas
  hit building these.
- **SAML**: configure AM as an IdP; stand up a SAML SP test app as the relying party.
  Console-based rebuild walkthrough (after the REST/Amster automation attempts hit
  dead ends): [SAML Federation Rebuild](https://claude.ai/artifact/U24QfzggdsevuuJzdiC1kV).
- **MFA** (done — TOTP/OATH): [mfa-setup-tree.sh](mfa-setup-tree.sh) creates a `PocMFA`
  tree in the root realm (username/password → Data Store Decision → OATH Token
  Verifier; users with no device go through OATH Registration first, then straight
  back to the Verifier to confirm their first code). The default `Login` tree is
  untouched. [mfa-otp-flow.sh](mfa-otp-flow.sh) tests it end-to-end without a phone:
  it registers a device for a dedicated `mfauser`, computes RFC 6238 codes from the
  `otpauth://` secret, and checks that a wrong code gets HTTP 401 and a fresh correct
  one gets a session. Browser (scan the QR with any authenticator app):
  `https://poc.example.com/am/XUI/?realm=/&authIndexType=service&authIndexValue=PocMFA`.
  Gotchas hit building it:
  - **The tree is lost whenever the AM pod is recreated.** In this ForgeOps
    setup, trees are file-based config in the pod's `emptyDir`, rebuilt from the
    image on every new pod (eviction, `rollout restart`, the AM recovery in
    `start-access.sh`). OAuth2 clients, SAML entities and circles of trust are
    stored in DS and survive. `start-access.sh` (step 4) checks for the tree and
    re-runs `mfa-setup-tree.sh` when it's missing; otherwise re-run it by hand.
  - Use the *Platform Username/Password* nodes (`ValidatedUsernameNode` /
    `ValidatedPasswordNode`, as in the stock `Login` tree), not the classic
    Username/Password Collectors. The platform nodes resolve the user to their
    `fr-idm-uuid`, which becomes the session/token subject. With the classic
    collectors the subject is the bare username, IDM can't map it to a
    `managed/user`, and the end-user UI dashboard stays empty after an MFA login.
  - The Registration node's QR code is just an `otpauth://` URI, also returned in a
    `HiddenValueCallback` with id `mfaDeviceRegistration`. That's what makes it scriptable.
  - TOTP codes are single-use: AM rejects a code from a 30s step that was already
    used, so a second login within the same step fails even with a "correct" code.
  - Device endpoints are addressed by the user's `fr-idm-uuid` (AM's users search
    attribute), not the username: `/json/realms/root/users/<uuid>/devices/2fa/oath`.
  - Recovery codes are turned off (`generateRecoveryCodes: false`) to keep the flow
    simple. To turn them on, set it to `true`, add a *Recovery Code Display Node*
    after Registration, and set `isRecoveryCodeAllowed: true` on the Verifier. That
    adds a `recoveryCodeOutcome`; wire it to a *Recovery Code Collector Decision*
    node (true → Success, false → Failure).
  - Device profiles are stored unencrypted in the user's `oathDeviceProfiles`
    attribute (the realm has no *ForgeRock Authenticator (OATH)* service configured,
    so encryption scheme `NONE` applies). That's fine for a POC. In production,
    add that service with an encryption keystore.
  - WebAuthn would slot into the same place (*WebAuthn Registration* /
    *WebAuthn Authentication* nodes), but it needs a real browser authenticator
    and an HTTPS origin matching `poc.example.com`, so it can't be tested with curl.
- **LDAP/DS** (done): [ds-connect.sh](ds-connect.sh) port-forwards `ds-idrepo`
  to `localhost:1636` (LDAPS) and `:1389` (LDAP), exports the DS CA (plus a Windows
  copy under `%USERPROFILE%\poc-ds\`), verifies the TLS handshake and prints
  bind details for `ldapsearch` and Apache Directory Studio.
  [ds-inspect.sh](ds-inspect.sh) is a read-only tour: naming contexts, the
  `ou=identities` layout, users, service accounts, one user broken down by which
  product owns each attribute, and which users have MFA devices. It never prints
  secrets. Gotchas:
  - The DS certificate is issued for `*.ds-idrepo`/`*.ds`/`*.ds-cts`, not
    `localhost`. Through the port-forward the CA verifies but the hostname doesn't
    match: use `LDAPTLS_REQCERT=allow` for OpenLDAP `ldapsearch`, and trust the
    certificate once in Directory Studio.
  - `uid=admin` is the directory superuser. Use it for inspection only; entries
    written behind IDM's back break the platform (§5 item 3).
  - IDM doesn't *sync* to `ds-idrepo`, it *is* backed by it: `managed/user` maps
    straight onto `ou=people,ou=identities` (`repo.ds.json`), and AM reads the
    same entries. One shared store, no reconciliation involved.
- **IDM provisioning**: define a mapping/reconciliation between IDM and DS.
- **CI/CD** (done, validation pipeline): see §9.

---

## 9. CI/CD

**Config as code.** All Helm overrides live in [values-poc.yaml](values-poc.yaml):
ingress host, `standard` storage class for both DS StatefulSets, and ds-idrepo
at 2Gi (§4.7). [deploy.sh](deploy.sh) installs with `-f values-poc.yaml`. Moving
the old `--set` flags into the file was verified to render identical manifests.
The only difference is the chart's `deployment-date` annotation, which is stamped
at render time. That annotation also means **every `helm upgrade` restarts every
pod**.

**Pipeline.** [.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every
push, every PR and on demand. It is a thin wrapper around
[ci-validate.sh](ci-validate.sh), so a local run gives the same result:

| Step | What | Fails on |
|---|---|---|
| shellcheck | all tracked `*.sh` | warnings/errors (style notes allowed, e.g. the deliberate unquoted `$CURL_OPTS`) |
| helm template | renders the chart with `values-poc.yaml` | chart/values errors |
| kubeconform | schema-validates rendered manifests + `saml-sp.yaml` | invalid resources (CRDs without bundled schemas are skipped) |
| policy | asserts the fixes this POC depends on: ds-idrepo memory 2Gi, `standard` storage class, ingress host | a silent regression (verified: reverting DS to 1366Mi fails the build) |

Tool versions are pinned in the workflow (shellcheck, kubeconform, yq, helm). The
rendered manifests are uploaded as a build artifact for review.

Run locally (needs shellcheck, helm, kubeconform, yq in `PATH`):
```bash
bash ci-validate.sh
```

**Why no deploy stage.** The repo is private. A GitHub-hosted runner can't reach
the local minikube, and a full platform deploy (~10–14 GB RAM) doesn't fit on
standard private-repo runners. Options if a deploy stage is wanted later:
- **Larger (paid) runner:** start minikube on the runner, run `deploy.sh`, then run
  `oidc-auth-code-flow.sh` / `mfa-otp-flow.sh` / `saml-sso-flow.sh` as integration
  tests, then tear down. About 20–30 minutes per run.
- **Self-hosted runner in WSL:** real CD to the local cluster. Only acceptable on
  this private repo, because the runner executes repo code on the workstation.
