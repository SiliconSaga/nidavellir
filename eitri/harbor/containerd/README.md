# containerd registry mirrors (client config)

These `hosts.toml` files point a cluster's node containerd at the public Harbor proxy-cache instead of pulling the failing upstreams directly. They are CLIENT config — applied per node, per substrate — separate from Harbor itself. Each installs at `/etc/containerd/certs.d/<upstream>/hosts.toml`.

## Docker Desktop / kind

The kind nodes are Docker containers (`desktop-control-plane`, `desktop-worker`).

**Quick path** — the helper wires both default nodes and both `xpkg.*` registries, verifies `config_path`, and prints a smoke-test (idempotent):

```
./wire-containerd-kind.sh                       # default Docker Desktop nodes
./wire-containerd-kind.sh <node> [<node> ...]   # explicit kind node containers
```

**Manual** — for each node and each upstream:

```
docker exec <node> mkdir -p /etc/containerd/certs.d/xpkg.crossplane.io
docker cp xpkg.crossplane.io.hosts.toml <node>:/etc/containerd/certs.d/xpkg.crossplane.io/hosts.toml
# repeat for xpkg.upbound.io
```

Confirm containerd reads `certs.d` (`config_path = "/etc/containerd/certs.d"` under the CRI registry section — kind images set this by default):

```
docker exec <node> grep -n 'config_path' /etc/containerd/config.toml
```

containerd reads `certs.d` per-pull, so no restart is needed once the files are in place. If `config_path` is missing, add it and restart containerd in the node, then force a re-pull (delete the stuck pods so kubelet retries):

```
kubectl delete pod -n crossplane --all
```

> **Windows / Git Bash:** `docker exec`/`docker cp` rewrite in-container absolute paths like `/etc/containerd/certs.d/...` into `C:/Program Files/Git/etc/...` (MSYS path conversion), so the manual commands above fail with "No such file or directory". Prefix them with `MSYS_NO_PATHCONV=1` (the helper script does this for you) or wrap the in-container command in `sh -c '...'`.
## k3s (homelab Rancher Desktop) — phase 3

k3s reads `/etc/rancher/k3s/registries.yaml` (an ordered `endpoint` list per mirror), not `certs.d`. Translate the same mapping there. Deferred to the phase-3 rollout.

## GKE nodes — phase 3

Node containerd config via a privileged DaemonSet that writes `certs.d` on each node. Deferred to phase-3.
