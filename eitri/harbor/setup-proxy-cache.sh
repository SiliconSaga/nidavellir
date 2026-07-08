#!/usr/bin/env bash
# Configure Harbor's public-read proxy-cache projects (idempotent).
#
# For each upstream: create a registry endpoint, then a PUBLIC project bound to
# it in proxy-cache mode. Anonymous pull works (public), so auth-less clusters
# (Docker Desktop) can mirror through it. Treats 201 (created) and 409 (exists)
# as success.
#
# Usage:  HARBOR_ADMIN_PW=<pw> bash setup-proxy-cache.sh
set -uo pipefail
BASE="${HARBOR_URL:-https://harbor.cmdbee.org}"
U="admin"; P="${HARBOR_ADMIN_PW:?set HARBOR_ADMIN_PW}"
api() { curl -sS -u "$U:$P" -H "Content-Type: application/json" "$@"; }

# name        type             url
# xpkg.* are generic OCI registries -> docker-registry. docker.io uses Harbor's
# docker-hub adapter (it knows the registry-1 endpoint). quay/ghcr work fine as
# generic docker-registry too.
mirrors="
crossplane docker-registry https://xpkg.crossplane.io
upbound    docker-registry https://xpkg.upbound.io
quay       docker-registry https://quay.io
ghcr       docker-registry https://ghcr.io
dockerhub  docker-hub       https://hub.docker.com
"

echo "$mirrors" | while read -r name type url; do
  [ -z "$name" ] && continue
  api -X POST "$BASE/api/v2.0/registries" \
    -d "{\"name\":\"$name\",\"type\":\"$type\",\"url\":\"$url\",\"insecure\":false}" \
    -o /dev/null -w "registry $name -> $url : %{http_code}\n"
  rid="$(api "$BASE/api/v2.0/registries?q=name%3D$name" | jq -r '.[0].id')"
  if [ -z "$rid" ] || [ "$rid" = "null" ]; then
    echo "  ! could not resolve registry id for $name — skipping project" >&2
    continue
  fi
  api -X POST "$BASE/api/v2.0/projects" \
    -d "{\"project_name\":\"$name\",\"registry_id\":$rid,\"metadata\":{\"public\":\"true\"}}" \
    -o /dev/null -w "project  $name (public proxy-cache) : %{http_code}\n"
done

echo "--- verify a real pull-through ---"
echo "docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4"
