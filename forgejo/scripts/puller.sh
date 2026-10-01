#!/usr/bin/env bash
# puller.sh — bring GitHub main to Forgejo main for every maintained repository:
# an anonymous fetch from GitHub, an authenticated push to Forgejo with
# --force-with-lease against the tip Forgejo had when this run started (an
# empty expectation when the branch does not exist yet, i.e. "must not exist").
# Only main is written; branches on Forgejo are untouched. One repository
# failing does not stop the others; the exit status is non-zero if any failed,
# which kube-prometheus-stack's KubeJobFailed reports.
#
# Runs as ServiceAccount forgejo-puller: no API token mounted, no OpenBao role.
# The Forgejo token reaches git through GIT_ASKPASS from a mounted Secret and
# never appears in a URL or an argument list; askpass.sh answers only for
# FORGEJO_URL, so a GitHub prompt (a missing or private upstream) fails instead
# of being offered the token. No GitHub credential exists.
#
# Every step checks its own status: `set -e` is inert inside a condition, and
# the first live run proved it — a failed GitHub fetch sailed through as
# "up to date".
set -uo pipefail
: "${FORGEJO_URL:=http://forgejo-http.forgejo.svc.cluster.local:3000}"
: "${ORG:?set ORG}"
: "${PULLER_USERNAME:?set PULLER_USERNAME}"
: "${PULLER_TOKEN_FILE:=/etc/forgejo-puller/token}"
: "${REPOS_FILE:=/etc/forgejo/repos}"
: "${ASKPASS:=/scripts/askpass.sh}"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 FORGEJO_URL PULLER_USERNAME PULLER_TOKEN_FILE
[ -s "$PULLER_TOKEN_FILE" ] || { echo "no token at $PULLER_TOKEN_FILE" >&2; exit 1; }

sync_repo() { # $1 = name, $2 = github owner/repo; runs in a fresh scratch clone
  local name="$1" upstream="$2" work expected incoming
  work=$(mktemp -d) || return 1
  (
    cd "$work" || exit 1
    git init -q -b main . || exit 1
    git remote add github "https://github.com/$upstream.git" || exit 1
    git remote add forgejo "$FORGEJO_URL/$ORG/$name.git" || exit 1
    # "main does not exist yet" and "Forgejo is unreachable" must not look the
    # same: the former means an empty lease (first push creates main), the
    # latter would turn into a forced push against a lease of nothing. ls-remote
    # --exit-code separates them: 2 is "ref absent", anything else non-zero is a
    # transport or auth failure.
    expected=""
    ls_rc=0
    git ls-remote --exit-code forgejo refs/heads/main >/dev/null 2>&1 || ls_rc=$?
    case "$ls_rc" in
      0)
        git fetch -q forgejo main || { echo "$name: fetch from forgejo failed" >&2; exit 1; }
        expected=$(git rev-parse -q --verify refs/remotes/forgejo/main) || exit 1 ;;
      2) ;;
      *) echo "$name: forgejo did not answer ls-remote (exit $ls_rc)" >&2; exit 1 ;;
    esac
    git fetch -q github main || { echo "$name: fetch from github.com/$upstream failed" >&2; exit 1; }
    incoming=$(git rev-parse -q --verify refs/remotes/github/main) || exit 1
    [ -n "$incoming" ] || { echo "$name: github main resolved to nothing" >&2; exit 1; }
    if [ "$incoming" = "$expected" ]; then
      echo "$name: up to date at ${incoming:0:12}"
      exit 0
    fi
    git push -q forgejo "--force-with-lease=refs/heads/main:$expected" refs/remotes/github/main:refs/heads/main \
      || { echo "$name: push to forgejo refused (lease ${expected:-<absent>})" >&2; exit 1; }
    echo "$name: ${expected:-<absent>} -> ${incoming:0:12}"
  )
  local rc=$?
  rm -rf "$work"
  return $rc
}

fails=0; total=0
while read -r name upstream; do
  [ -z "$name" ] && continue
  total=$((total+1))
  sync_repo "$name" "$upstream" || { echo "$name: FAILED" >&2; fails=$((fails+1)); }
done < "$REPOS_FILE"
echo "puller: $((total-fails))/$total repositories in sync"
[ "$fails" -eq 0 ]
