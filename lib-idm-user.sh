# shellcheck shell=bash
# Shared helper, sourced by oidc-setup-client.sh and mfa-otp-flow.sh:
#   ensure_idm_user <userName> <password> <givenName> <sn> <mail>
#
# End users MUST be created through IDM (managed/user), not AM's
# /json/realms/root/users?_action=create. AM writes a bare LDAP entry that is
# missing IDM's objectClass (fr-idm-managed-user-hybrid-obj) and meta record
# (fr-idm-managed-user-meta), so:
#   - IDM queries never return the user -> the platform "Login" tree fails
#     ("No object to increment" / "Login count is not supported")
#   - AM identifies the user by username instead of fr-idm-uuid, so IDM can't
#     map the OAuth token's sub -> end-user UI dashboard is empty (IDM 503s)
# Such legacy users are detected and recreated (same username/password, new
# fr-idm-uuid).
#
# IDM password policy: the password may not contain userName, givenName or sn.
#
# Expects in the caller: BASE_URL, HOST_HDR, CURL_OPTS, NAMESPACE, ADMIN_TOKEN
# (amadmin session). Optional: IDM_URL (default: BASE_URL with /am -> /openidm;
# when BASE_URL is an AM port-forward, also run
#   kubectl port-forward -n poc svc/idm 18081:80
# and set IDM_URL=http://localhost:18081/openidm).

IDM_URL="${IDM_URL:-${BASE_URL%/am}/openidm}"

# idm_curl <curl args...> -- authenticated as AM's idm-provisioning OAuth client
idm_curl() {
  if [ -z "${IDM_TOKEN:-}" ]; then
    local secret
    secret=$(kubectl get secret amster-env-secrets -n "$NAMESPACE" \
      -o jsonpath='{.data.IDM_PROVISIONING_CLIENT_SECRET}' | base64 -d)
    IDM_TOKEN=$(curl -s $CURL_OPTS -H "Host: $HOST_HDR" -u "idm-provisioning:$secret" \
      -d grant_type=client_credentials -d 'scope=fr:idm:*' \
      "$BASE_URL/oauth2/realms/root/access_token" | jq -r '.access_token // empty')
    if [ -z "$IDM_TOKEN" ]; then
      echo "ERROR: could not get an idm-provisioning token from AM" >&2
      return 1
    fi
  fi
  curl -s $CURL_OPTS -H "Host: $HOST_HDR" -H "Authorization: Bearer $IDM_TOKEN" \
    -H 'Content-Type: application/json' "$@"
}

ensure_idm_user() {
  local user=$1 password=$2 given=$3 sn=$4 mail=$5 id status resp

  id=$(idm_curl "$IDM_URL/managed/user?_queryFilter=userName%20eq%20%22$user%22&_fields=_id" \
    | jq -r '.result[0]._id // empty')

  if [ -n "$id" ]; then
    # A healthy IDM user has a login-count profile (what the Login tree uses)
    status=$(idm_curl -o /dev/null -w '%{http_code}' "$IDM_URL/profile/managed/user/$id/loginCount")
    if [ "$status" = "200" ]; then
      echo "    user '$user' already exists in IDM, leaving it as-is"
      return 0
    fi
    echo "    user '$user' exists but was not created by IDM (no login-count profile) -- recreating"
    idm_curl -X DELETE -H 'If-Match: *' -o /dev/null "$IDM_URL/managed/user/$id"
  elif curl -s $CURL_OPTS -H "Host: $HOST_HDR" -H "iPlanetDirectoryPro: $ADMIN_TOKEN" \
         -H "Accept-API-Version: resource=3.0, protocol=1.0" \
         "$BASE_URL/json/realms/root/users?_queryFilter=uid%20eq%20%22$user%22&_fields=username" \
         | jq -e '.resultCount > 0' >/dev/null; then
    echo "    user '$user' exists in AM but is invisible to IDM (created via AM REST) -- recreating"
    curl -s $CURL_OPTS -X DELETE -o /dev/null -H "Host: $HOST_HDR" -H "iPlanetDirectoryPro: $ADMIN_TOKEN" \
      -H "Accept-API-Version: resource=3.0, protocol=1.0" "$BASE_URL/json/realms/root/users/$user"
  fi

  echo "    creating user '$user' via IDM"
  resp=$(idm_curl -X POST \
    --data "$(jq -n --arg u "$user" --arg p "$password" --arg g "$given" --arg s "$sn" --arg m "$mail" \
      '{userName: $u, password: $p, givenName: $g, sn: $s, mail: $m}')" \
    "$IDM_URL/managed/user?_action=create&_fields=_id,userName")
  if ! echo "$resp" | jq -e '._id' >/dev/null 2>&1; then
    echo "ERROR: IDM user creation failed: $resp" >&2
    return 1
  fi
  echo "    created: $(echo "$resp" | jq -c '{_id, userName}')"
}
