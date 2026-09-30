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
# never appears in a URL or an argument list. No GitHub credential exists.
set -uo pipefail
: "${FORGEJO_URL:=http://forgejo-http.forgejo.svc.cluster.local:3000}"
: "${ORG:?set ORG}"
: "${PULLER_USERNAME:?set PULLER_USERNAME}"
: "${PULLER_TOKEN_FILE:=/etc/forgejo-puller/token}"
: "${REPOS_FILE:=/etc/forgejo/repos}"
: "${ASKPASS:=/scripts/askpass.sh}"
export GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 PULLER_USERNAME PULLER_TOKEN_FILE
[ -s "$PULLER_TOKEN_FILE" ] || { echo "no token at $PULLER_TOKEN_FILE" >&2; exit 1; }

fails=0; total=0
while read -r name upstream; do
  [ -z "$name" ] && continue
  total=$((total+1))
  work=$(mktemp -d)
  if (
    set -e
    cd "$work"
    git init -q -b main .
    git remote add github "https://github.com/$upstream.git"
    git remote add forgejo "$FORGEJO_URL/$ORG/$name.git"
    expected=""
    if git fetch -q forgejo main 2>/dev/null; then
      expected=$(git rev-parse -q --verify refs/remotes/forgejo/main)
    fi
    git fetch -q github main
    incoming=$(git rev-parse -q --verify refs/remotes/github/main)
    if [ "$incoming" = "$expected" ]; then
      echo "$name: up to date at ${incoming:0:12}"
      exit 0
    fi
    git push -q forgejo "--force-with-lease=refs/heads/main:$expected" refs/remotes/github/main:refs/heads/main
    echo "$name: ${expected:-<absent>} -> ${incoming:0:12}"
  ); then :; else
    echo "$name: FAILED" >&2
    fails=$((fails+1))
  fi
  rm -rf "$work"
done < "$REPOS_FILE"
echo "puller: $((total-fails))/$total repositories in sync"
[ "$fails" -eq 0 ]
