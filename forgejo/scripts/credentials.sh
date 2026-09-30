#!/usr/bin/env bash
# credentials.sh — mint Forgejo's admin and break-glass passwords in OpenBao,
# create-only, over the HTTP API with Kubernetes auth. Runs once per claim
# generation as ServiceAccount forgejo-init (composition.yaml, credentials-job).
#
# For every path: read secret/metadata/<path>; 404 means absent, so generate a
# password and write secret/data/<path> with options.cas: 0, which OpenBao
# refuses if any version exists — a retry, or a concurrent writer, can never
# overwrite a value. Any other status is an error and the Job fails. A sealed
# or unreachable OpenBao fails before any write, loudly.
#
# Values rest only in 0600 files under a 0700 scratch dir; nothing is printed.
set -euo pipefail
: "${OPENBAO_ADDR:=http://openbao.openbao.svc:8200}"
: "${OPENBAO_ROLE:=forgejo-init}"
: "${ADMIN_USERNAME:=forgejo-admin}"
: "${BREAK_GLASS_ADMINS:=}"
: "${SA_TOKEN_FILE:=/var/run/secrets/kubernetes.io/serviceaccount/token}"

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

health=$(curl -sS -o /dev/null -w '%{http_code}' "$OPENBAO_ADDR/v1/sys/health" || true)
case "$health" in
  200|429|472|473) ;;
  503) echo "OpenBao is SEALED ($OPENBAO_ADDR/v1/sys/health -> 503); refusing to continue." >&2; exit 2 ;;
  501) echo "OpenBao is not initialized (501); refusing to continue." >&2; exit 2 ;;
  *) echo "OpenBao unreachable or unhealthy (sys/health -> ${health:-no response})." >&2; exit 2 ;;
esac

jq -n --rawfile jwt "$SA_TOKEN_FILE" --arg role "$OPENBAO_ROLE" \
  '{role: $role, jwt: ($jwt | rtrimstr("\n"))}' > "$work/login.json"
if ! curl -fsS -X POST --data @"$work/login.json" "$OPENBAO_ADDR/v1/auth/kubernetes/login" > "$work/login-resp.json"; then
  echo "OpenBao Kubernetes-auth login as role $OPENBAO_ROLE failed — is the role configured (nordri openbao-configure.sh)?" >&2
  exit 2
fi
jq -r '"header = \"X-Vault-Token: " + .auth.client_token + "\""' "$work/login-resp.json" > "$work/curl.cfg"
rm -f "$work/login.json" "$work/login-resp.json"

ensure() { # $1 = KV path below secret/, $2 = username stored beside the password
  local path="$1" user="$2" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -K "$work/curl.cfg" "$OPENBAO_ADDR/v1/secret/metadata/$path")
  case "$code" in
    200) echo "present: secret/$path"; return 0 ;;
    404) ;;
    *) echo "reading secret/metadata/$path returned HTTP $code" >&2; return 1 ;;
  esac
  head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "$work/pw"
  [ "$(wc -c < "$work/pw")" -eq 32 ] || { echo "password generation for secret/$path came up short" >&2; return 1; }
  jq -n --rawfile pw "$work/pw" --arg u "$user" \
    '{options: {cas: 0}, data: {username: $u, password: $pw}}' > "$work/put.json"
  code=$(curl -sS -o "$work/put-resp.json" -w '%{http_code}' -K "$work/curl.cfg" \
    -X POST --data @"$work/put.json" "$OPENBAO_ADDR/v1/secret/data/$path")
  rm -f "$work/pw" "$work/put.json"
  case "$code" in
    200) echo "created: secret/$path" ;;
    400)
      if grep -q "check-and-set" "$work/put-resp.json"; then
        echo "created meanwhile by another writer: secret/$path"
      else
        echo "writing secret/$path returned HTTP 400: $(cat "$work/put-resp.json")" >&2; return 1
      fi ;;
    *) echo "writing secret/$path returned HTTP $code: $(cat "$work/put-resp.json")" >&2; return 1 ;;
  esac
}

ensure forgejo "$ADMIN_USERNAME"
for u in $BREAK_GLASS_ADMINS; do
  ensure "forgejo/admins/$u" "$u"
done
echo "forgejo credentials: done"
