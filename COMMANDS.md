# Command Reference

Commands used to build, debug and operate this POC, grouped by task. Companion to
[INSTALLATION.md](INSTALLATION.md), which explains *why* each fix was needed.

Conventions:
- Run everything **inside WSL** (`wsl -d Ubuntu-24.04`) unless noted. The cluster's
  kubeconfig only exists there. On Windows, `kubectl` fails with
  `localhost:8080 ... connection refused`.
- Namespace is `poc` throughout.
- Secrets are always **fetched live**, never pasted in. Nothing here contains a
  password.
- ⚠️ marks commands that **change state**. Everything else is read-only.

Contents:
1. [Cluster and pod status](#1-cluster-and-pod-status)
2. [Logs and events](#2-logs-and-events)
3. [Secrets and credentials](#3-secrets-and-credentials)
4. [Port-forwards](#4-port-forwards)
5. [AM REST API](#5-am-rest-api)
6. [IDM REST API](#6-idm-rest-api)
7. [DS / LDAP](#7-ds--ldap)
8. [OAuth2 / OIDC and TOTP by hand](#8-oauth2--oidc-and-totp-by-hand)
9. [Recovery and fixes](#9-recovery-and-fixes)
10. [Resources and memory](#10-resources-and-memory)
11. [Helm and CI](#11-helm-and-ci)
12. [Repo scripts](#12-repo-scripts)
13. [Running from Windows (Git Bash / PowerShell)](#13-running-from-windows-git-bash--powershell)

---

## 1. Cluster and pod status

```bash
wsl -l -v                                     # (Windows) which distros run; cluster lives in Ubuntu-24.04
minikube status
minikube profile list
kubectl get nodes
kubectl get pods -n poc -o wide
kubectl get pods -n poc -w                    # watch until all Running/Completed
kubectl get pod -n poc -l app=am              # one component by label
kubectl get ingress -n poc -o custom-columns=NAME:.metadata.name,PATHS:.spec.rules[*].http.paths[*].path
kubectl get svc -n poc ds-idrepo -o json | jq -c '[.spec.ports[] | {name, port}]'
kubectl get endpoints idm -n poc

# Why isn't a pod Ready? Container state, restarts, last termination reason
kubectl get pod ds-idrepo-0 -n poc -o json \
  | jq -c '.status.containerStatuses[0] | {ready, restartCount, lastState, state}'
kubectl describe pod -n poc -l app=am | sed -n '/Events:/,$p'
kubectl describe node minikube | grep -A8 -E '^Conditions|Allocated resources'

# Wait for things
kubectl wait --for=condition=Ready pod/ds-idrepo-0 -n poc --timeout=300s
kubectl rollout status deploy/am -n poc --timeout=420s
kubectl rollout status sts/ds-idrepo -n poc --timeout=600s
```

Inside a pod:
```bash
kubectl exec -n poc deploy/am -c openam -- date -u +%T          # clock check (TOTP needs sane clocks)
kubectl exec -n poc deploy/am -c openam -- cat /home/forgerock/docker-entrypoint.sh
kubectl exec -n poc deploy/am -c openam -- ls -la /home/forgerock/openam/security/keystores/boot
kubectl exec -n poc deploy/idm -c openidm -- cat /opt/openidm/conf/authentication.json
kubectl exec -n poc deploy/idm -c openidm -- cat /opt/openidm/conf/repo.ds.json
kubectl get deploy am -n poc -o yaml | grep -A40 '^      volumes:'   # which dirs are emptyDir
```

## 2. Logs and events

```bash
kubectl logs -n poc deploy/am -c openam --tail=60
kubectl logs -n poc deploy/am -c openam --since=15m
kubectl logs ds-idrepo-0 -n poc -c ds --previous | tail -15       # the run that crashed
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --since=15m

# AM: first real startup error (skip health-check noise)
kubectl logs -n poc deploy/am | grep -iE 'ldap|connect|SEVERE|ERROR' | grep -v 'health/live' | head -20

# AM: which tree ran and what each node returned (audit events are JSON lines)
kubectl logs -n poc deploy/am -c openam --since=10m \
  | grep -E 'AM-TREE-LOGIN-COMPLETED|AM-NODE-LOGIN-COMPLETED' \
  | jq -rc '[.timestamp[11:19], (.principal|tostring), .entries[0].info.treeName,
             (.entries[0].info.displayName // ""), (.entries[0].info.nodeOutcome // .result // "")] | @tsv'

# AM: full stack of one exception
kubectl logs -n poc deploy/am -c openam --since=20m | grep OathVerificationException | tail -1 | jq -r .exception

# IDM: requests AM made to IDM, with status codes
kubectl logs -n poc deploy/idm --since=10m | grep '"eventName":"access"' | grep idm-provisioning \
  | jq -c '{t: .timestamp[11:19], m: .http.request.method, p: .http.request.path, s: .response.statusCode}'

# Ingress: what the browser actually requested (path + status), minus static assets
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --since=15m \
  | grep -vE 'sessionCheck|\.(js|css|png|svg|woff2?|ico|json)[ ?]' | awk '{print $4, $6, substr($7,1,160), $9}'

# Ingress: 503s per minute on /openidm
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --since=90m | grep '/openidm' \
  | awk '{split($4,t,":"); print t[2]":"t[3], $9}' | sort | uniq -c
```

## 3. Secrets and credentials

```bash
kubectl get secrets -n poc
kubectl get secret am-env-secrets -n poc -o json | jq -r '.data | keys[]'     # list keys without values

# amadmin (AM)
kubectl get secret am-env-secrets -n poc -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d
# uid=admin (DS directory superuser)
kubectl get secret ds-passwords -n poc -o jsonpath='{.data.dirmanager\.pw}' | base64 -d
# openidm-admin (IDM -- header auth is rejected in platform mode; use OAuth, §6)
kubectl get secret idm-env-secrets -n poc -o jsonpath='{.data.OPENIDM_ADMIN_PASSWORD}' | base64 -d
# AM's OAuth clients for calling IDM
kubectl get secret amster-env-secrets -n poc -o jsonpath='{.data.IDM_PROVISIONING_CLIENT_SECRET}' | base64 -d

# DS TLS: CA + server cert details (SANs are *.ds-idrepo/*.ds/*.ds-cts, not localhost)
kubectl get secret ds-ssl-keypair -n poc -o jsonpath='{.data.ca\.crt}' | base64 -d > ds-ca.pem
kubectl get secret ds-ssl-keypair -n poc -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName
```

## 4. Port-forwards

| Target | Command | Used for |
|---|---|---|
| AM | `kubectl port-forward -n poc svc/am 18080:80` | REST scripts with `BASE_URL=http://localhost:18080/am` |
| IDM | `kubectl port-forward -n poc svc/idm 18081:80` | `IDM_URL=http://localhost:18081/openidm` |
| DS | `kubectl port-forward -n poc svc/ds-idrepo 1636:1636 1389:1389` | ldapsearch / Directory Studio (`ds-connect.sh`) |
| Ingress | `sudo -E kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 443:443 80:80` | browser + SAML flow (`start-access.sh`) |

```bash
nohup kubectl port-forward -n poc svc/am 18080:80 > /tmp/am-pf.log 2>&1 &    # background it
pgrep -af port-forward                                                     # what's running
pkill -f 'port-forward -n poc svc/'                                        # stop the poc ones
```

Through a port-forward, AM checks the `Host` header, so always send
`-H 'Host: poc.example.com'`. Otherwise AM answers "Realm not found".

## 5. AM REST API

Setup used by every example below:
```bash
B=http://localhost:18080/am; H='Host: poc.example.com'
PW=$(kubectl get secret am-env-secrets -n poc -o jsonpath='{.data.AM_PASSWORDS_AMADMIN_CLEAR}' | base64 -d)
T=$(curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $PW" \
  -H 'Accept-API-Version: resource=2.0, protocol=1.0' \
  "$B/json/realms/root/authenticate" | jq -r .tokenId)
A=(-s -H "$H" -H "iPlanetDirectoryPro: $T" -H 'Content-Type: application/json' -H 'Accept-API-Version: resource=1.0')
TREES=$B/json/realms/root/realm-config/authentication/authenticationtrees
```

Health and sessions:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" $B/json/health/live
curl -s -H "$H" -H "iPlanetDirectoryPro: <session>" -H 'Content-Type: application/json' \
  -H 'Accept-API-Version: resource=4.0' -X POST "$B/json/realms/root/sessions?_action=getSessionInfo" \
  | jq -c '{username, universalId}'          # universalId should be id=<fr-idm-uuid>,...
```

Trees and nodes:
```bash
curl "${A[@]}" "$TREES/trees?_queryFilter=true&_fields=_id" | jq -c '[.result[]._id]'
curl "${A[@]}" "$TREES/trees/Login" | jq .                                   # structure of a tree
curl "${A[@]}" "$TREES/nodes/PageNode/<id>" | jq -c .
curl "${A[@]}" -X POST "$TREES/nodes/OathRegistrationNode?_action=template" | jq -c .      # node defaults
curl "${A[@]}" -X POST -d '{"isRecoveryCodeAllowed":false}' \
  "$TREES/nodes/OathTokenVerifierNode?_action=listOutcomes" | jq -c .                        # node outcomes
curl "${A[@]}" -X POST "$TREES/nodes?_action=getAllTypes" | jq -r '.result[]._id'           # all node types
# ⚠️ create/replace a node or tree: PUT the JSON (see mfa-setup-tree.sh); delete:
curl "${A[@]}" -X DELETE "$TREES/trees/PocMFA"
```

Realm services and identity store:
```bash
curl "${A[@]}" "$B/json/realms/root/realm-config/services?_queryFilter=true" | jq -c '[.result[]._id]'
curl "${A[@]}" -X POST "$B/json/realms/root/realm-config/services/authenticatorOathService?_action=template" | jq -c .
curl "${A[@]}" "$B/json/realms/root/realm-config/services/id-repositories/LDAPv3ForForgeRockIAM/OpenDJ" \
  | jq '.userconfig' | grep -iE 'search|naming'           # users-search-attribute = fr-idm-uuid
curl "${A[@]}" "$B/json/realms/root/realm-config/services/oauth-oidc" | jq -c .coreOIDCConfig
```

Users, devices, federation:
```bash
# filter on the LDAP attribute uid -- "username eq" matches nothing here
curl "${A[@]}" -H 'Accept-API-Version: resource=3.0, protocol=1.0' \
  "$B/json/realms/root/users?_queryFilter=uid%20eq%20%22demouser%22&_fields=username"
# MFA devices are addressed by fr-idm-uuid, not username
curl "${A[@]}" "$B/json/realms/root/users/<uuid>/devices/2fa/oath?_queryFilter=true" | jq -c '[.result[]._id]'
curl "${A[@]}" -X DELETE "$B/json/realms/root/users/<uuid>/devices/2fa/oath/<device-id>"     # ⚠️
curl "${A[@]}" -o /dev/null -w '%{http_code}\n' "$B/json/realms/root/realm-config/agents/OAuth2Client/poc-test-client"
curl "${A[@]}" "$B/json/realms/root/realm-config/saml2?_queryFilter=true" | jq -c '[.result[].entityId]'
curl "${A[@]}" "$B/json/realms/root/realm-config/federation/circlesoftrust?_queryFilter=true" | jq -c '[.result[]._id]'
curl -s -H "$H" "$B/saml2/jsp/exportmetadata.jsp?entityid=https://poc.example.com/am&realm=/" | head -c 300
```

Stepping through a tree by hand (callbacks in, callbacks out):
```bash
U="$B/json/realms/root/authenticate?authIndexType=service&authIndexValue=PocMFA"
C=(-s -H "$H" -H 'Content-Type: application/json' -H 'Accept-API-Version: resource=2.1, protocol=1.0')
R=$(curl "${C[@]}" -X POST "$U"); echo "$R" | jq -c '[.callbacks[].type]'
R=$(echo "$R" | jq '.callbacks[0].input[0].value="demouser" | .callbacks[1].input[0].value="Demo@12345"' \
    | curl "${C[@]}" -X POST -d @- "$U")
echo "$R" | jq '.callbacks | map({type, output})'     # e.g. the OATH QR / otpauth:// URI
```

## 6. IDM REST API

In platform mode IDM only accepts AM-issued bearer tokens. Get one as AM's
`idm-provisioning` client (client credentials, **basic** auth):
```bash
CS=$(kubectl get secret amster-env-secrets -n poc -o jsonpath='{.data.IDM_PROVISIONING_CLIENT_SECRET}' | base64 -d)
AT=$(curl -s -H 'Host: poc.example.com' -u "idm-provisioning:$CS" \
  -d grant_type=client_credentials -d 'scope=fr:idm:*' \
  http://localhost:18080/am/oauth2/realms/root/access_token | jq -r .access_token)
I=http://localhost:18081/openidm          # or, without a port-forward, from inside the AM pod:
# kubectl exec -n poc deploy/am -c openam -- curl -s -H "Authorization: Bearer $AT" http://idm:80/openidm/...
```

```bash
curl -s -H "Authorization: Bearer $AT" "$I/info/ping"                  # ACTIVE_READY
curl -s -H "Authorization: Bearer $AT" "$I/managed/user?_queryFilter=userName%20eq%20%22demouser%22&_fields=_id,userName" | jq -c .
curl -s -H "Authorization: Bearer $AT" "$I/managed/user/<uuid>?_fields=_id,userName,givenName,sn,mail,accountStatus" | jq -c .
curl -s -H "Authorization: Bearer $AT" "$I/profile/managed/user/<uuid>/loginCount"   # 200 = healthy IDM user
curl -s -H "Authorization: Bearer $AT" "$I/policy/managed/user" \
  | jq -c '.properties[] | select(.name=="password") | [.policies[] | {policyId, params}]'
# ⚠️ create a user the right way (through IDM; password may not contain userName/givenName/sn)
curl -s -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' -X POST \
  -d '{"userName":"jdoe","password":"Str0ng#Pass","givenName":"Jane","sn":"Doe","mail":"jdoe@poc.example.com"}' \
  "$I/managed/user?_action=create&_fields=_id,userName"
# ⚠️ delete
curl -s -H "Authorization: Bearer $AT" -H 'If-Match: *' -X DELETE "$I/managed/user/<uuid>"
```

## 7. DS / LDAP

Easiest: `bash ds-connect.sh` (port-forward + CA + connection details) and
`bash ds-inspect.sh [user]` (read-only tour).

With the DS tools inside the pod (no local install needed):
```bash
PW=$(kubectl get secret ds-passwords -n poc -o jsonpath='{.data.dirmanager\.pw}' | base64 -d)
L() { kubectl exec -n poc ds-idrepo-0 -c ds -- ldapsearch -h localhost -p 1636 -Z -X -D uid=admin -w "$PW" "$@"; }
L -b "" -s base "(objectClass=*)" namingContexts vendorVersion      # root DSE
L -b ou=identities -s one "(objectClass=*)" dn                      # people, groups, admins, o=root
L -b ou=people,ou=identities "(uid=demouser)" '*' '+'               # full entry incl. operational attrs
L -b ou=people,ou=identities "(oathDeviceProfiles=*)" uid           # who has an OATH device
L -b ou=admins,ou=identities -s one "(objectClass=*)" dn            # service accounts
```

From WSL through the port-forward (`sudo apt-get install -y ldap-utils` first):
```bash
export LDAPTLS_CACERT=/tmp/poc-logs/ds-idrepo-ca.pem LDAPTLS_REQCERT=allow   # cert isn't issued for localhost
ldapsearch -LLL -x -H ldaps://localhost:1636 -D uid=admin -W \
  -b ou=people,ou=identities '(uid=demouser)' uid cn mail fr-idm-uuid
```

Apache Directory Studio: host `localhost`, port `1636`, "Use SSL encryption",
trust the certificate, then Simple auth with `uid=admin`.

⚠️ Writing to DS directly (historical, **don't repeat**). This was the first
attempt at making AM-created users visible to IDM. It was superseded by
recreating the users through IDM (§6):
```bash
printf 'dn: fr-idm-uuid=<uuid>,ou=people,ou=identities\nchangetype: modify\nadd: objectClass\nobjectClass: fr-idm-managed-user-hybrid-obj\n' \
  | kubectl exec -i -n poc ds-idrepo-0 -c ds -- ldapmodify -h localhost -p 1636 -Z -X -D uid=admin -w "$PW"
```

## 8. OAuth2 / OIDC and TOTP by hand

What the end-user UI does (authorization code + PKCE with the `end-user-ui` client),
then call IDM with the token. A 200 from `/openidm/info/login` means the
dashboard will work:
```bash
VER=$(head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | head -c 64)
CH=$(printf %s "$VER" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
RU=https://poc.example.com/enduser/appAuthHelperRedirect.html
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -H "$H" -b "iPlanetDirectoryPro=<session>" \
  "$B/oauth2/realms/root/authorize?client_id=end-user-ui&response_type=code&scope=openid%20fr:idm:*&redirect_uri=$RU&code_challenge=$CH&code_challenge_method=S256&state=x")
CODE=$(echo "$LOC" | sed -nE 's/.*[?&]code=([^&]*).*/\1/p')
AT=$(curl -s -H "$H" -d grant_type=authorization_code -d client_id=end-user-ui -d "code=$CODE" \
  -d "code_verifier=$VER" -d "redirect_uri=$RU" "$B/oauth2/realms/root/access_token" | jq -r .access_token)
curl -s -H "$H" -H "Authorization: Bearer $AT" http://localhost:18081/openidm/info/login | jq -c .
```

Current TOTP code from a base32 secret (what an authenticator app computes):
```bash
python3 -c "import base64,hashlib,hmac,struct,time,sys;s=sys.argv[1].rstrip('=');k=base64.b32decode(s+'='*(-len(s)%8));h=hmac.new(k,struct.pack('>Q',int(time.time())//30),hashlib.sha1).digest();o=h[-1]&15;print('%06d'%((struct.unpack('>I',h[o:o+4])[0]&0x7fffffff)%1000000))" <BASE32_SECRET>
```
To turn a stored device's hex `sharedSecret` (from `oathDeviceProfiles`) into an app key:
`python3 -c "import base64,sys;print(base64.b32encode(bytes.fromhex(sys.argv[1])).decode().rstrip('='))" <HEX>`

MFA login in a browser (the end-user UI drops `authIndexValue`, so start at AM):
`https://poc.example.com/am/XUI/?realm=/&authIndexType=service&authIndexValue=PocMFA&goto=https%3A%2F%2Fpoc.example.com%2Fenduser%2F`

## 9. Recovery and fixes

```bash
# ⚠️ AM stuck on "Can't open boot keystore" (INSTALLATION.md 4.8): fresh pod = clean emptyDir
kubectl delete pod -n poc -l app=am
# ⚠️ restart AM (clears its identity cache; also wipes REST-created trees -> re-run mfa-setup-tree.sh)
kubectl rollout restart deploy/am -n poc
# ⚠️ ds-idrepo OOMKilled (INSTALLATION.md 4.7): 2Gi without a helm upgrade (avoids re-running amster)
kubectl patch sts ds-idrepo -n poc --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"limits":{"memory":"2Gi"},"requests":{"cpu":"500m","memory":"2Gi"}}}]'
# JVM flags a pod actually runs with (e.g. MaxRAMPercentage)
kubectl exec -n poc ds-idrepo-0 -c ds -- sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in *java*) echo "$c" | grep -oE "\-XX:[^ ]+|-X[^ ]+" | sort -u;; esac; done'
```

## 10. Resources and memory

```bash
kubectl top pods -n poc
docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} ({{.MemPerc}})' minikube
docker inspect minikube --format '{{.HostConfig.Memory}}'            # node container limit (bytes)
docker info --format 'docker VM: cpus={{.NCPU}} mem={{.MemTotal}}'
grep -oE '"(Memory|CPUs|DiskSize)": *[0-9]+' ~/.minikube/profiles/minikube/config.json
# ⚠️ raise the node's memory in place, no restart (start-access.sh does this automatically)
docker update --memory 14g --memory-swap 14g minikube
```
Symptom of a starved node: `kubectl` fails with `TLS handshake timeout` while
`minikube status` still says Running.

## 11. Helm and CI

```bash
helm get values identity-platform -n poc                                   # overrides in the live release
helm show values oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform --version 7.5
helm template identity-platform oci://us-docker.pkg.dev/forgeops-public/charts/identity-platform \
  --version 7.5 --namespace poc -f values-poc.yaml > rendered.yaml
kubeconform -strict -ignore-missing-schemas -summary rendered.yaml saml-sp.yaml
yq ea 'select(.kind=="StatefulSet" and .metadata.name=="ds-idrepo") | .spec.template.spec.containers[0].resources' rendered.yaml
shellcheck -x -S warning $(git ls-files '*.sh')
bash ci-validate.sh                                                         # all of the above, as CI runs it
```

## 12. Repo scripts

| Script | Purpose |
|---|---|
| `setup-wsl.sh` | one-time CLI tool install in WSL |
| `deploy.sh` / `teardown.sh` | ⚠️ deploy / remove the platform (Helm, `values-poc.yaml`) |
| `start-access.sh` | bring everything up after a reboot: Docker, minikube, node memory, AM recovery, MFA tree, ingress port-forward, tunnel |
| `oidc-setup-client.sh` / `oidc-auth-code-flow.sh` | OAuth client + demo user (via IDM) / end-to-end code flow |
| `saml-sso-flow.sh` / `saml-teardown.sh` | SAML SSO test against the SimpleSAMLphp SP |
| `mfa-setup-tree.sh` / `mfa-otp-flow.sh` | create the `PocMFA` TOTP tree / end-to-end MFA test |
| `ds-connect.sh` / `ds-inspect.sh` | LDAP port-forward + details / read-only tour of the identity repository |
| `ci-validate.sh` | CI checks (shellcheck, helm template, kubeconform, policy) |
| `lib-idm-user.sh` | sourced helper: create users through IDM |

Most accept `BASE_URL=http://localhost:18080/am` (plus `IDM_URL=http://localhost:18081/openidm`)
to run through port-forwards instead of the ingress.

## 13. Running from Windows (Git Bash / PowerShell)

```bash
wsl -d Ubuntu-24.04 -- bash -lc "kubectl get pods -n poc"          # simple one-liners
wsl -d Ubuntu-24.04 --cd /mnt/c/Users/vijay/PoC -- bash start-access.sh
```
Gotchas:
- **Anything with quotes, `$`, `jq` filters or `-o jsonpath` gets mangled** passing
  through `wsl` → `bash -c`. Put the commands in a `.sh` file and run
  `wsl -d Ubuntu-24.04 -- bash /mnt/c/path/to/file.sh`.
- From Git Bash, prefix with `MSYS_NO_PATHCONV=1` so `/mnt/c/...` isn't rewritten into
  `C:/Program Files/Git/mnt/c/...`.
- PowerShell 5.1 prints `wsl -l -v` output with spaces between letters (UTF-16);
  the content is fine.
- WSL2 forwards `localhost` ports to Windows, so a port-forward started in WSL
  (e.g. DS on 1636) is reachable from Windows apps at `localhost`.
