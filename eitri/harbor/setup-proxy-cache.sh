#!/usr/bin/env bash
# Configure Harbor's public-read proxy-cache projects (idempotent).
#
# For each upstream: create a registry endpoint, then a PUBLIC project bound to
# it in proxy-cache mode. Anonymous pull works (public), so auth-less clusters
# (Docker Desktop) can mirror through it. Treats 2xx (created) and 409 (exists)
# as success; any other status fails the run.
#
# Usage:  HARBOR_ADMIN_PW=<pw> bash setup-proxy-cache.sh
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "❌ setup-proxy-cache.sh requires jq on PATH." >&2; exit 1; }
BASE="${HARBOR_URL:-https://harbor.cmdbee.org}"
U="admin"; P="${HARBOR_ADMIN_PW:?set HARBOR_ADMIN_PW}"
# Auth via a stdin curl config (-K -) so the admin password never lands on the
# process argv (readable via ps / /proc/<pid>/cmdline for the call's duration).
api() {
  curl -sS -H "Content-Type: application/json" -K - "$@" <<EOF
user = "$U:$P"
EOF
}

# name       type            url
# xpkg.* + quay/ghcr are generic docker-registry; docker.io uses Harbor's
# docker-hub adapter (it knows the registry-1 endpoint).
mirrors="
crossplane docker-registry https://xpkg.crossplane.io
upbound    docker-registry https://xpkg.upbound.io
quay       docker-registry https://quay.io
ghcr       docker-registry https://ghcr.io
dockerhub  docker-hub       https://hub.docker.com
"

fails=0
ok() { case "$1" in 2*|409) return 0 ;; *) return 1 ;; esac; }   # created or already-exists

# Here-string (not a pipe) so the loop runs in this shell and $fails survives it.
while read -r name type url; do
  [ -z "$name" ] && continue
  code="$(api -X POST "$BASE/api/v2.0/registries" \
    -d "{\"name\":\"$name\",\"type\":\"$type\",\"url\":\"$url\",\"insecure\":false}" \
    -o /dev/null -w "%{http_code}")"
  echo "registry $name -> $url : $code"
  ok "$code" || { echo "  ! unexpected status for registry '$name': $code" >&2; fails=$((fails + 1)); }

  rid="$(api "$BASE/api/v2.0/registries?q=name%3D$name" | jq -r '.[0].id')"
  if [ -z "$rid" ] || [ "$rid" = "null" ]; then
    echo "  ! could not resolve registry id for '$name' — skipping project" >&2
    fails=$((fails + 1))
    continue
  fi
  code="$(api -X POST "$BASE/api/v2.0/projects" \
    -d "{\"project_name\":\"$name\",\"registry_id\":$rid,\"metadata\":{\"public\":\"true\"}}" \
    -o /dev/null -w "%{http_code}")"
  echo "project  $name (public proxy-cache) : $code"
  ok "$code" || { echo "  ! unexpected status for project '$name': $code" >&2; fails=$((fails + 1)); }
done <<< "$mirrors"

if [ "$fails" -ne 0 ]; then
  echo "❌ $fails Harbor API call(s) returned an unexpected status." >&2
  exit 1
fi

echo "--- verify a real pull-through ---"
echo "docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4"
