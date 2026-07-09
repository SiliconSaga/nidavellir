# containerd registry mirrors (client config)

Client-side config that points a cluster's node container runtime at the public Harbor proxy-cache for the `xpkg.*` registries, instead of pulling them from the upstream directly. It's separate from Harbor itself and applied per node.

The **mapping is identical everywhere** — route `xpkg.crossplane.io` → `harbor.<domain>/v2/crossplane` and `xpkg.upbound.io` → `harbor.<domain>/v2/upbound` (the two `hosts.toml` files here). Only **how you deliver it to the nodes differs by substrate**, because runtimes read mirror config from different places.

## containerd via `certs.d` (Docker Desktop, kind, generic containerd)

containerd reads per-registry mirror files from `/etc/containerd/certs.d/<upstream>/hosts.toml` — but only when its config has `config_path = "/etc/containerd/certs.d"` (the CRI registry section; kind images set this by default). The files are read per-pull, so no containerd restart is needed once they're in place.

On Docker Desktop / kind the nodes are Docker containers, so the helper installs them:

```
./wire-containerd-kind.sh                       # default Docker Desktop nodes (desktop-control-plane, desktop-worker)
./wire-containerd-kind.sh <node> [<node> ...]   # explicit kind node containers
```

Manual equivalent (per node, per upstream):

```
docker exec <node> mkdir -p /etc/containerd/certs.d/xpkg.crossplane.io
docker cp xpkg.crossplane.io.hosts.toml <node>:/etc/containerd/certs.d/xpkg.crossplane.io/hosts.toml
```

Check `config_path` and, if it's absent, add it + restart containerd, then delete the stuck pods so kubelet re-pulls:

```
docker exec <node> grep -n config_path /etc/containerd/config.toml   # want: config_path = "/etc/containerd/certs.d"
kubectl delete pod -n crossplane --all
```

## k3s (Rancher Desktop, pure k3s, k3d)

k3s does **not** read `certs.d` directly — it owns `/etc/rancher/k3s/registries.yaml` and generates the containerd mirror config from it. So on any k3s cluster (Rancher Desktop and a plain k3s install alike) you translate the same mapping into `registries.yaml` rather than copying the `hosts.toml`:

```yaml
mirrors:
  xpkg.crossplane.io:
    endpoint:
      - "https://harbor.<domain>/v2/crossplane"
  xpkg.upbound.io:
    endpoint:
      - "https://harbor.<domain>/v2/upbound"
```

Write that on each node and restart k3s (`systemctl restart k3s` on a server, `k3s-agent` on an agent). k3s turns it into the same `certs.d` hosts.toml under the hood; confirm the endpoint path-rewrite behavior against the k3s registry docs for your version.

## GKE / managed nodes

Same `certs.d` mechanism as the first section, but you can't `docker exec`/`docker cp` into managed nodes. Deliver the `hosts.toml` with a privileged **DaemonSet** (or a node-startup script) that writes `/etc/containerd/certs.d/<upstream>/hosts.toml` on every node and ensures `config_path` is set. It must be persistent: managed node pools recreate nodes on autoscale/upgrade, and each new node needs the config. (A public-read Harbor needs no node credentials; a private/authenticated mirror would add that as the extra piece.)

## Windows / Git Bash

`docker exec`/`docker cp` rewrite in-container absolute paths like `/etc/containerd/certs.d/...` into `C:/Program Files/Git/etc/...` (MSYS path conversion), so the manual commands fail with "No such file or directory". Prefix them with `MSYS_NO_PATHCONV=1` (the helper script does this) or wrap the in-container command in `sh -c '...'`.
