#!/usr/bin/env bash
# Exposes the identity repository (ds-idrepo) on localhost so LDAP clients --
# ldapsearch in WSL, Apache Directory Studio on Windows -- can connect:
#   1. kubectl port-forward svc/ds-idrepo  -> localhost:1636 (LDAPS), :1389 (LDAP)
#      (WSL2 forwards localhost ports to Windows, so Studio uses localhost too)
#   2. Exports the DS CA certificate so clients can trust the LDAPS cert
#   3. Verifies the TLS handshake through the tunnel
#   4. Prints connection details + example commands
#
# Usage: bash ds-connect.sh           (tour of the data: bash ds-inspect.sh)
# Stop:  pkill -f 'port-forward -n poc svc/ds-idrepo'
#
# Env overrides: NAMESPACE, LDAPS_PORT (1636), LDAP_PORT (1389), LOG_DIR, CA_FILE
#
# Notes:
#   - The DS server cert is issued for *.ds-idrepo / *.ds / *.ds-cts, not
#     "localhost", so clients connecting to localhost see a hostname mismatch.
#     The CA is still verifiable; ldapsearch needs LDAPTLS_REQCERT=allow and
#     Directory Studio asks you to trust the certificate once.
#   - Plain LDAP on 1389 accepts simple binds too. Through the port-forward the
#     hop to the cluster is tunnelled over the Kubernetes API (TLS), but the
#     password crosses localhost in clear text -- prefer 1636.
#   - uid=admin is the directory superuser (full read/write on everything).
#     Use it for inspection; don't modify entries IDM/AM own (see
#     INSTALLATION.md §5 for what happens when entries bypass IDM).
set -uo pipefail

NAMESPACE="${NAMESPACE:-poc}"
LDAPS_PORT="${LDAPS_PORT:-1636}"
LDAP_PORT="${LDAP_PORT:-1389}"
LOG_DIR="${LOG_DIR:-/tmp/poc-logs}"
CA_FILE="${CA_FILE:-$LOG_DIR/ds-idrepo-ca.pem}"
mkdir -p "$LOG_DIR"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

echo "==> 1/4 Port-forward svc/ds-idrepo -> localhost:$LDAPS_PORT (LDAPS), localhost:$LDAP_PORT (LDAP)"
if pgrep -f "port-forward -n $NAMESPACE svc/ds-idrepo" >/dev/null; then
  echo "    already running"
else
  nohup kubectl port-forward -n "$NAMESPACE" svc/ds-idrepo "$LDAPS_PORT:1636" "$LDAP_PORT:1389" \
    > "$LOG_DIR/ds-port-forward.log" 2>&1 &
  disown
  for _ in $(seq 1 15); do port_open "$LDAPS_PORT" && break; sleep 1; done
  if ! port_open "$LDAPS_PORT"; then
    echo "ERROR: port-forward didn't come up -- see $LOG_DIR/ds-port-forward.log"
    exit 1
  fi
  echo "    started (log: $LOG_DIR/ds-port-forward.log)"
fi

echo "==> 2/4 Exporting DS CA certificate"
kubectl get secret ds-ssl-keypair -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"
echo "    $CA_FILE ($(openssl x509 -in "$CA_FILE" -noout -subject))"

echo "==> 3/4 Verifying LDAPS handshake through the tunnel"
VERIFY=$(openssl s_client -connect "127.0.0.1:$LDAPS_PORT" -CAfile "$CA_FILE" </dev/null 2>/dev/null \
  | grep -m1 'Verify return code')
echo "    ${VERIFY:-no TLS response}"
case "$VERIFY" in *"0 (ok)"*) ;; *) echo "    WARNING: certificate chain did not verify against $CA_FILE" ;; esac

echo "==> 4/4 Connection details"
ADMIN_PW=$(kubectl get secret ds-passwords -n "$NAMESPACE" -o jsonpath='{.data.dirmanager\.pw}' | base64 -d)
WIN_CA=""
if command -v wslpath >/dev/null; then
  WIN_CA_DIR="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")/poc-ds"
  mkdir -p "$WIN_CA_DIR" 2>/dev/null && cp "$CA_FILE" "$WIN_CA_DIR/ds-idrepo-ca.pem" 2>/dev/null \
    && WIN_CA="$(wslpath -w "$WIN_CA_DIR/ds-idrepo-ca.pem")"
fi

cat <<EOF

  Host / port   localhost:$LDAPS_PORT  (LDAPS)   or  localhost:$LDAP_PORT  (LDAP, StartTLS optional)
  Bind DN       uid=admin
  Password      $ADMIN_PW
  Base DNs      ou=identities                  users (ou=people), groups, service accounts
                ou=am-config                   AM data stored in DS (OAuth clients, SAML, policies)
                ou=tokens                      AM session tokens
                dc=openidm,dc=forgerock,dc=io  IDM internals (links, config, scheduler)
  CA cert       $CA_FILE${WIN_CA:+
                $WIN_CA  (Windows copy)}

  ldapsearch (WSL -- needs: sudo apt-get install -y ldap-utils):
    export LDAPTLS_CACERT=$CA_FILE LDAPTLS_REQCERT=allow
    ldapsearch -LLL -x -H ldaps://localhost:$LDAPS_PORT -D uid=admin -W \\
      -b ou=people,ou=identities '(uid=demouser)' uid cn mail fr-idm-uuid

  Apache Directory Studio (Windows): New LDAP Connection ->
    Hostname localhost, Port $LDAPS_PORT, Encryption "Use SSL encryption (ldaps://)"
    -> Check Network Parameter -> trust the certificate (hostname mismatch is expected)
    -> Simple Authentication, Bind DN uid=admin, the password above.
    Browser Options: tick "Get base DNs from Root DSE".

  Guided tour of the data: bash ds-inspect.sh
  Stop the tunnel:         pkill -f 'port-forward -n $NAMESPACE svc/ds-idrepo'
EOF
