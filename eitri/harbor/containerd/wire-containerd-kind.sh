#!/usr/bin/env bash
# Wire a Docker Desktop / kind cluster's node containerd at the public Harbor
# proxy-cache, so its nodes pull the xpkg.* registries through Harbor instead
# of failing on the direct upstream. Idempotent — safe to re-run.
#
# Usage:
#   ./wire-containerd-kind.sh [node ...]
#     No args  → the default Docker Desktop kind nodes:
#                  desktop-control-plane desktop-worker
#     node ... → explicit node (container) names, e.g. for a plain kind cluster:
#                  ./wire-containerd-kind.sh mycluster-control-plane mycluster-worker
#
# Reads the sibling <registry>.hosts.toml files. containerd reads certs.d
# per-pull, so no restart is needed — kind images set config_path by default;
# the script warns if a node doesn't have it.
#
# Windows / Git Bash: MSYS_NO_PATHCONV stops the in-container /etc/... dest paths
# being rewritten to C:/Program Files/Git/etc/...  That would also leave a
# $(pwd)-style source (/d/...) unconverted, which docker.exe misreads as D:\d —
# so the host-side source path is passed through cygpath -w. (Both are no-ops on
# Linux/macOS.) See README ("Windows / Git Bash").
set -uo pipefail
export MSYS_NO_PATHCONV=1

HERE="$(cd "$(dirname "$0")" && pwd)"
REGISTRIES=(xpkg.crossplane.io xpkg.upbound.io)

# Render a host path in the form docker.exe expects (Windows path under Git Bash,
# unchanged elsewhere).
to_host_path() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

NODES=("$@")
if [ ${#NODES[@]} -eq 0 ]; then
  NODES=(desktop-control-plane desktop-worker)
fi

rc=0
for node in "${NODES[@]}"; do
  if ! docker inspect "$node" >/dev/null 2>&1; then
    echo "⚠️  node container '$node' not found — skipping" >&2
    rc=1
    continue
  fi
  if ! docker exec "$node" grep -qE '^[[:space:]]*config_path[[:space:]]*=[[:space:]]*"[^"]*certs\.d' /etc/containerd/config.toml; then
    echo "⚠️  $node: containerd config_path is not '/etc/containerd/certs.d' — the hosts.toml will be ignored until you set it and restart containerd." >&2
    rc=1
  fi
  for reg in "${REGISTRIES[@]}"; do
    src="$HERE/$reg.hosts.toml"
    if [ ! -f "$src" ]; then
      echo "❌ missing $src" >&2
      rc=1
      continue
    fi
    if docker exec "$node" mkdir -p "/etc/containerd/certs.d/$reg" &&
       docker cp "$(to_host_path "$src")" "$node:/etc/containerd/certs.d/$reg/hosts.toml"; then
      echo "✅ $node: $reg → Harbor"
    else
      echo "❌ $node: failed to install $reg hosts.toml" >&2
      rc=1
    fi
  done
done

echo
echo "Smoke-test a pull-through on a node (expect a digest, not an EOF/timeout):"
echo "  docker exec ${NODES[0]} crictl pull xpkg.crossplane.io/crossplane/crossplane:v2.1.4"
exit "$rc"
