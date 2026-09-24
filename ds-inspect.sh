#!/usr/bin/env bash
# Guided, read-only tour of the identity repository (ds-idrepo): what's in each
# naming context, the users and service accounts, one user entry in detail
# (showing which attributes belong to DS, AM and IDM), and which users have MFA
# devices registered. Secrets (password hashes, OATH shared secrets) are never
# printed.
#
# Uses local ldapsearch through the ds-connect.sh port-forward when available
# (the "real" client path), otherwise the ldapsearch bundled in the DS pod.
#
# Usage: bash ds-inspect.sh [username]      (default: demouser)
# Env overrides: NAMESPACE, LDAPS_PORT (1636), CA_FILE, VIA=local|pod
set -uo pipefail

NAMESPACE="${NAMESPACE:-poc}"
LDAPS_PORT="${LDAPS_PORT:-1636}"
CA_FILE="${CA_FILE:-/tmp/poc-logs/ds-idrepo-ca.pem}"
USER_ID="${1:-demouser}"
ADMIN_PW=$(kubectl get secret ds-passwords -n "$NAMESPACE" -o jsonpath='{.data.dirmanager\.pw}' | base64 -d)

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
if [ -z "${VIA:-}" ]; then
  if command -v ldapsearch >/dev/null && port_open "$LDAPS_PORT" && [ -f "$CA_FILE" ]; then VIA=local; else VIA=pod; fi
fi

# ldq <ldapsearch args: -b base [-s scope] filter [attrs...]> -- same flags for both clients
ldq() {
  if [ "$VIA" = "local" ]; then
    LDAPTLS_CACERT="$CA_FILE" LDAPTLS_REQCERT=allow \
      ldapsearch -LLL -o ldif-wrap=no -x -H "ldaps://localhost:$LDAPS_PORT" -D uid=admin -w "$ADMIN_PW" "$@"
  else
    kubectl exec -n "$NAMESPACE" ds-idrepo-0 -c ds -- \
      ldapsearch -h localhost -p 1636 -Z -X -D uid=admin -w "$ADMIN_PW" "$@" 2>/dev/null
  fi
}
count() { ldq "$@" 1.1 | grep -c '^dn:'; }
section() { printf '\n==> %s\n' "$1"; }

if [ "$VIA" = "local" ]; then
  echo "Client: local ldapsearch -> ldaps://localhost:$LDAPS_PORT (port-forward)"
else
  echo "Client: ldapsearch inside ds-idrepo-0 (for the port-forward path: bash ds-connect.sh +"
  echo "        sudo apt-get install -y ldap-utils)"
fi

section "1. Naming contexts (root DSE)"
ldq -b "" -s base "(objectClass=*)" namingContexts vendorVersion | grep -vE '^dn:|^$'
cat <<'EOF'
    ou=identities        -> identity repository: users, groups, service accounts
    ou=am-config         -> AM data kept in DS (OAuth2 clients, SAML entities, policies)
    ou=tokens            -> AM session tokens
    dc=openidm,...       -> IDM internals (links, config, scheduler, relationships)
    uid=admin/monitor/proxy -> DS's own administrative accounts
EOF

section "2. ou=identities layout"
for ou in people groups admins; do
  printf '    %-32s %s entries\n' "ou=$ou,ou=identities" "$(count -b "ou=$ou,ou=identities" -s one "(objectClass=*)")"
done

section "3. Users (ou=people)"
ldq -b "ou=people,ou=identities" -s one "(objectClass=inetOrgPerson)" uid cn mail fr-idm-uuid inetUserStatus \
  | awk '/^dn:/{if(r)print r; r=""; next} /^$/{next} {sub(/: /,"="); r=r (r?"  ":"    ") $0} END{if(r)print r}'

section "4. Service accounts (ou=admins,ou=identities)"
ldq -b "ou=admins,ou=identities" -s one "(objectClass=*)" dn | grep '^dn:' | sed 's/^/    /'
echo "    (AM binds as am-identity-bind-account; see its identity store config)"

section "5. User '$USER_ID' in detail"
ENTRY=$(ldq -b "ou=people,ou=identities" "(uid=$USER_ID)" '*' '+')
if [ -z "$(echo "$ENTRY" | grep '^dn:')" ]; then
  echo "    no user with uid=$USER_ID"
else
  echo "$ENTRY" | grep '^dn:' | sed 's/^/    /'
  echo "    -- core LDAP attributes"
  echo "$ENTRY" | grep -E '^(uid|cn|sn|givenName|mail|inetUserStatus):' | sed 's/^/      /'
  echo "    -- IDM: fr-idm-uuid is the platform-wide identity id (AM's users search"
  echo "       attribute, the OAuth token 'sub', and IDM's managed/user _id)"
  echo "$ENTRY" | grep -E '^fr-idm-uuid:' | sed 's/^/      /'
  echo "$ENTRY" | grep -E '^fr-idm-managed-user-meta:' | cut -c1-110 | sed 's/^/      /;s/$/.../'
  echo "    -- objectClasses (fr-idm-* from IDM, iplanet-*/sunFM*/*DeviceProfilesContainer from AM)"
  echo "$ENTRY" | awk '/^objectClass:/{printf "%s%s", (n++?", ":"      "), $2} END{print ""}' | fold -s -w 100 | sed '2,$s/^/      /'
  echo "    -- operational attributes"
  echo "$ENTRY" | grep -E '^(createTimestamp|modifyTimestamp|pwdChangedTime|entryUUID|creatorsName):' | sed 's/^/      /'
  echo "    -- MFA / secrets (values hidden)"
  for a in userPassword oathDeviceProfiles webauthnDeviceProfiles pushDeviceProfiles; do
    n=$(echo "$ENTRY" | grep -c "^$a:")
    [ "$n" -gt 0 ] && echo "      $a: $n value(s)"
  done
fi

section "6. Users with MFA devices registered"
for a in oathDeviceProfiles webauthnDeviceProfiles pushDeviceProfiles; do
  users=$(ldq -b "ou=people,ou=identities" "($a=*)" uid | awk '/^uid:/{printf "%s ", $2}')
  printf '    %-24s %s\n' "$a" "${users:-(none)}"
done

section "7. Entries per naming context"
for b in ou=identities ou=am-config ou=tokens dc=openidm,dc=forgerock,dc=io; do
  printf '    %-32s %s\n' "$b" "$(count -b "$b" "(objectClass=*)")"
done
echo
