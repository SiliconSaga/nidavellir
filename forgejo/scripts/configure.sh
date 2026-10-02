#!/usr/bin/env bash
# configure.sh — reconcile Forgejo's org, repositories, puller token, branch
# protection, vendor mirrors and break-glass accounts from the claim. Runs after
# the release is ready, as ServiceAccount forgejo-init, authenticating to the
# REST API as the admin with the password ESO delivered (a mounted file, never
# an argument). Every step is check-then-act; existing maintained repositories
# are never modified. Exit codes: 0 done, 1 an API or tooling failure, 3 the
# puller token is in a state this Job refuses to repair (PullerTokenInvalid).
#
# ROTATE=puller revokes the Forgejo token named "puller", mints a replacement
# and rewrites Secret forgejo-puller. Run it as a one-off Job (docs/forgejo.md).
#
# Forgejo 15 has no force-push allowlist: a protected branch rejects
# non-fast-forward pushes from everyone. Repositories are therefore created
# EMPTY (no auto_init), so the puller's first push creates main instead of
# replacing an initial commit.
set -uo pipefail
: "${FORGEJO_URL:=http://forgejo-http.forgejo.svc.cluster.local:3000}"
: "${ORG:?set ORG}"
: "${ADMIN_USERNAME:=forgejo-admin}"
: "${ADMIN_PASSWORD_FILE:=/etc/forgejo-admin/password}"
: "${ADMINS_DIR:=/etc/forgejo-admins}"
: "${BREAK_GLASS_ADMINS:=}"
: "${EMAIL_DOMAIN:?set EMAIL_DOMAIN}"
: "${REPOS_FILE:=/etc/forgejo/repos}"
: "${MIRRORS_FILE:=/etc/forgejo/mirrors}"
: "${NAMESPACE:=forgejo}"
: "${PULLER_SECRET:=forgejo-puller}"
: "${PULLER_TOKEN_NAME:=puller}"
: "${ROTATE:=}"

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
RESP="$work/resp"
AUTH_CFG="$work/auth.cfg"
printf 'user = "%s:%s"\n' "$ADMIN_USERNAME" "$(cat "$ADMIN_PASSWORD_FILE")" > "$AUTH_CFG"
fails=0

api() { # api <method> </v1 path> [curl args]  -> prints the HTTP status; body lands in $RESP
  local method="$1" path="$2"; shift 2
  curl -sS -o "$RESP" -w '%{http_code}' -K "$AUTH_CFG" -H 'Content-Type: application/json' \
    -X "$method" "$@" "$FORGEJO_URL/api/v1$path"
}
body() { head -c 400 "$RESP" 2>/dev/null; }

echo "waiting for $FORGEJO_URL/api/healthz"
code=""
for _ in $(seq 1 60); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$FORGEJO_URL/api/healthz" || true)
  [ "$code" = 200 ] && break
  sleep 5
done
[ "$code" = 200 ] || { echo "Forgejo did not answer /api/healthz with 200 within 5 minutes (last: ${code:-none})" >&2; exit 1; }

# ── 1. organisation ────────────────────────────────────────────────────────
code=$(api GET "/orgs/$ORG")
case "$code" in
  200) echo "org $ORG: present" ;;
  404)
    jq -n --arg u "$ORG" '{username: $u, visibility: "public"}' > "$work/body.json"
    code=$(api POST /orgs --data @"$work/body.json")
    [ "$code" = 201 ] && echo "org $ORG: created" || { echo "creating org $ORG: HTTP $code $(body)" >&2; exit 1; } ;;
  *) echo "GET /orgs/$ORG: HTTP $code $(body)" >&2; exit 1 ;;
esac

# ── 2. maintained repositories, created empty ──────────────────────────────
while read -r name upstream; do
  [ -z "$name" ] && continue
  code=$(api GET "/repos/$ORG/$name")
  case "$code" in
    200) echo "repo $ORG/$name: present" ;;
    404)
      jq -n --arg n "$name" --arg d "main is written by the puller from https://github.com/$upstream" \
        '{name: $n, description: $d, private: false, auto_init: false, default_branch: "main"}' > "$work/body.json"
      code=$(api POST "/orgs/$ORG/repos" --data @"$work/body.json")
      [ "$code" = 201 ] && echo "repo $ORG/$name: created (empty)" || { echo "creating $ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)); } ;;
    *) echo "GET /repos/$ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)) ;;
  esac
done < "$REPOS_FILE"

# ── 3. the puller token: keep, mint, or refuse ─────────────────────────────
token_cfg="$work/token.cfg"
secret_present=false
if kubectl get secret -n "$NAMESPACE" "$PULLER_SECRET" >/dev/null 2>&1; then
  secret_present=true
  # A Secret that exists but cannot be read or decoded is not "invalid token",
  # it is a broken Job environment — stop before the state machine below
  # mistakes it for a token Forgejo rejected.
  kubectl get secret -n "$NAMESPACE" "$PULLER_SECRET" -o jsonpath='{.data.token}' | base64 -d > "$work/token" \
    || { echo "reading Secret $NAMESPACE/$PULLER_SECRET failed" >&2; exit 1; }
  [ -s "$work/token" ] || { echo "Secret $NAMESPACE/$PULLER_SECRET carries an empty token" >&2; exit 1; }
  printf 'header = "Authorization: token %s"\n' "$(cat "$work/token")" > "$token_cfg"
fi
token_valid=false
if $secret_present; then
  # A write:repository token has no read:user scope, so GET /user answers 401
  # for a perfectly good token (found on the first live run). Validate against
  # a repository-scoped endpoint instead. Only 401/403 mean "Forgejo rejected
  # this token"; a transport failure or any other status is not evidence
  # about the token and must not feed the mint-or-refuse decision.
  code=$(curl -sS -o "$RESP" -w '%{http_code}' -K "$token_cfg" "$FORGEJO_URL/api/v1/repos/search?limit=1") \
    || { echo "validating the puller token: curl failed (${code:-no status})" >&2; exit 1; }
  case "$code" in
    200) token_valid=true ;;
    401|403) token_valid=false ;;
    *) echo "validating the puller token: HTTP $code $(body)" >&2; exit 1 ;;
  esac
fi
code=$(api GET "/users/$ADMIN_USERNAME/tokens")
[ "$code" = 200 ] || { echo "listing $ADMIN_USERNAME's tokens: HTTP $code $(body)" >&2; exit 1; }
named_present=$(jq --arg n "$PULLER_TOKEN_NAME" '[.[] | select(.name == $n)] | length > 0' "$RESP")

mint_puller() {
  jq -n --arg n "$PULLER_TOKEN_NAME" '{name: $n, scopes: ["write:repository"]}' > "$work/body.json"
  code=$(api POST "/users/$ADMIN_USERNAME/tokens" --data @"$work/body.json")
  [ "$code" = 201 ] || { echo "minting token $PULLER_TOKEN_NAME: HTTP $code $(body)" >&2; return 1; }
  jq -r '.sha1' "$RESP" | tr -d '\n' > "$work/token"
  rm -f "$RESP"
  [ -s "$work/token" ] || { echo "token response carried no sha1" >&2; return 1; }
  kubectl create secret generic "$PULLER_SECRET" -n "$NAMESPACE" --from-file=token="$work/token" \
    --dry-run=client -o yaml > "$work/secret.yaml"
  if $secret_present; then kubectl replace -f "$work/secret.yaml" >/dev/null; else kubectl create -f "$work/secret.yaml" >/dev/null; fi
}

case "$ROTATE:$secret_present:$token_valid:$named_present" in
  puller:*)
    code=$(api DELETE "/users/$ADMIN_USERNAME/tokens/$PULLER_TOKEN_NAME")
    case "$code" in 204|404) ;; *) echo "revoking token $PULLER_TOKEN_NAME: HTTP $code $(body)" >&2; exit 1 ;; esac
    mint_puller || exit 1
    echo "puller token: rotated" ;;
  :true:true:true) echo "puller token: present and valid" ;;
  :false:false:false) mint_puller || exit 1; echo "puller token: minted" ;;
  # The Secret outlived the Forgejo instance (a teardown and re-graduation, a
  # database restore): Forgejo holds no token of that name, so minting leaves
  # nothing untracked behind — the whole reason the refusal below exists.
  :true:false:false) mint_puller || exit 1; echo "puller token: Secret outlived the instance; minted afresh" ;;
  *)
    echo "PullerTokenInvalid: Secret $NAMESPACE/$PULLER_SECRET present=$secret_present valid=$token_valid; Forgejo token '$PULLER_TOKEN_NAME' on $ADMIN_USERNAME present=$named_present. A token's value cannot be read back, so this Job will not mint another on its own: run it with ROTATE=puller (docs/forgejo.md)." >&2
    exit 3 ;;
esac

# ── 4. break-glass admins, with the passwords ESO delivered ────────────────
# Before branch protection: the push allowlist names these accounts, and
# Forgejo rejects a rule naming a user that does not exist yet.
for u in $BREAK_GLASS_ADMINS; do
  pwfile="$ADMINS_DIR/$u/password"
  [ -s "$pwfile" ] || { echo "no password mounted for break-glass admin $u at $pwfile (ExternalSecret forgejo-admin-$u not synced?)" >&2; fails=$((fails+1)); continue; }
  code=$(api GET "/users/$u")
  case "$code" in
    200) echo "user $u: present" ;;
    404)
      jq -n --arg u "$u" --arg e "$u@$EMAIL_DOMAIN" --rawfile p "$pwfile" '{
        username: $u, email: $e, password: ($p | rtrimstr("\n")),
        must_change_password: false, send_notify: false, visibility: "private"}' > "$work/body.json"
      code=$(api POST /admin/users --data @"$work/body.json")
      rm -f "$work/body.json"
      [ "$code" = 201 ] && echo "user $u: created" || { echo "creating user $u: HTTP $code $(body)" >&2; fails=$((fails+1)); continue; } ;;
    *) echo "GET /users/$u: HTTP $code $(body)" >&2; fails=$((fails+1)); continue ;;
  esac
  jq -n '{admin: true, must_change_password: false}' > "$work/body.json"
  code=$(api PATCH "/admin/users/$u" --data @"$work/body.json")
  [ "$code" = 200 ] && echo "user $u: admin" || { echo "PATCH /admin/users/$u: HTTP $code $(body)" >&2; fails=$((fails+1)); }
done

# ── 5. main branch protection on every maintained repository ───────────────
# Pushes allowed for the admin (the puller's token is the admin's) and the
# break-glass accounts only. Forgejo 15 protects against force pushes for
# everyone; there is no allowlist for that (see header).
printf '%s\n' "$ADMIN_USERNAME" $BREAK_GLASS_ADMINS | jq -R . | jq -sc . > "$work/allow.json"
jq -n --slurpfile users "$work/allow.json" '{
  enable_push: true, enable_push_whitelist: true, push_whitelist_usernames: $users[0],
  push_whitelist_teams: [], push_whitelist_deploy_keys: false,
  enable_merge_whitelist: false, enable_status_check: false, required_approvals: 0,
  block_on_rejected_reviews: false, block_on_outdated_branch: false,
  dismiss_stale_approvals: false, require_signed_commits: false}' > "$work/edit.json"
jq '. + {rule_name: "main"}' "$work/edit.json" > "$work/create.json"
while read -r name _; do
  [ -z "$name" ] && continue
  code=$(api GET "/repos/$ORG/$name/branch_protections/main")
  case "$code" in
    200)
      code=$(api PATCH "/repos/$ORG/$name/branch_protections/main" --data @"$work/edit.json")
      [ "$code" = 200 ] && echo "protection $ORG/$name main: reconciled" || { echo "PATCH protection $ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)); } ;;
    404)
      code=$(api POST "/repos/$ORG/$name/branch_protections" --data @"$work/create.json")
      [ "$code" = 201 ] && echo "protection $ORG/$name main: created" || { echo "POST protection $ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)); } ;;
    *) echo "GET protection $ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)) ;;
  esac
done < "$REPOS_FILE"

# ── 6. vendor mirrors: Forgejo pull-mirrors, tags included ─────────────────
# The API cannot change a pull mirror's upstream after creation, so a mirror
# whose original_url differs from the claim is deleted and re-migrated. A
# mirror is derived data; nothing of ours lives in it. Forgejo 15.0.9 fills
# original_url for a service: git migration (verified live); the empty case
# is tolerated for older or different versions.
create_mirror() { # $1 = name, $2 = upstream
  jq -n --arg n "$1" --arg u "$2" --arg o "$ORG" '{
    clone_addr: $u, repo_name: $n, repo_owner: $o, mirror: true, service: "git",
    private: false, wiki: false, issues: false, pull_requests: false, releases: true,
    labels: false, milestones: false, lfs: false, description: ("Pull mirror of " + $u)}' > "$work/body.json"
  code=$(api POST /repos/migrate --data @"$work/body.json")
  [ "$code" = 201 ] && echo "mirror $ORG/$1: created from $2" || { echo "migrating $2 as $ORG/$1: HTTP $code $(body)" >&2; return 1; }
}
while read -r name upstream; do
  [ -z "$name" ] && continue
  code=$(api GET "/repos/$ORG/$name")
  case "$code" in
    200)
      is_mirror=$(jq -r '.mirror' "$RESP"); orig=$(jq -r '.original_url // ""' "$RESP")
      if [ "$is_mirror" = true ] && [ -z "$orig" ]; then
        echo "mirror $ORG/$name: present (original_url empty; upstream drift is not detectable on this version)"
      elif [ "$is_mirror" = true ] && [ "$orig" = "$upstream" ]; then
        echo "mirror $ORG/$name: present ($orig)"
      else
        echo "mirror $ORG/$name: mirror=$is_mirror upstream=${orig:-?}, claim says $upstream — recreating"
        code=$(api DELETE "/repos/$ORG/$name")
        [ "$code" = 204 ] || { echo "deleting $ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)); continue; }
        create_mirror "$name" "$upstream" || fails=$((fails+1))
      fi ;;
    404) create_mirror "$name" "$upstream" || fails=$((fails+1)) ;;
    *) echo "GET /repos/$ORG/$name: HTTP $code $(body)" >&2; fails=$((fails+1)) ;;
  esac
done < "$MIRRORS_FILE"

[ "$fails" -eq 0 ] || { echo "forgejo configure: $fails step(s) failed" >&2; exit 1; }
echo "forgejo configure: done"
