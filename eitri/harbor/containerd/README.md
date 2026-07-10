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

Check `config_path` and, if it's absent, add it + restart containerd, then delete only the specific stuck pods (or roll the affected deployment) so kubelet re-pulls — don't nuke every pod in the `crossplane` namespace, or you'll disrupt unrelated providers/functions/compositions:

```bash
docker exec <node> grep -n config_path /etc/containerd/config.toml   # want: config_path = "/etc/containerd/certs.d"
kubectl get pods -n crossplane                                       # identify the stuck pod(s) — e.g. ImagePullBackOff
kubectl delete pod -n crossplane <stuck-pod-name> [<stuck-pod-name> ...]
# or, if the pod belongs to a Deployment:
kubectl rollout restart deployment/<affected-deployment> -n crossplane
```

## k3s (Rancher Desktop, pure k3s, k3d)

k3s does **not** read `certs.d` directly — it owns `/etc/rancher/k3s/registries.yaml` and generates the containerd mirror config from it. So on any k3s cluster (Rancher Desktop and a plain k3s install alike) you translate the same mapping into `registries.yaml` rather than copying the `hosts.toml`:

```yaml
mirrors:
  xpkg.crossplane.io:
    endpoint:
      - "https://harbor.<domain>/v2/crossplane"       # local mirror
      - "https://harbor.cmdbee.org/v2/crossplane"     # central cache
      - "https://xpkg.crossplane.io"                  # upstream origin
  xpkg.upbound.io:
    endpoint:
      - "https://harbor.<domain>/v2/upbound"          # local mirror
      - "https://harbor.cmdbee.org/v2/upbound"        # central cache
      - "https://xpkg.upbound.io"                     # upstream origin
```

List each registry's endpoints in that order — local mirror, then central cache, then upstream origin — so a pull falls back local → central → origin: if the local Harbor hasn't cached an image yet (or is still bootstrapping), the pull tries the central cache next, and only hits the true origin as a last resort.

Write that on each node and restart k3s (`systemctl restart k3s` on a server, `k3s-agent` on an agent). k3s turns it into the same `certs.d` hosts.toml under the hood; confirm the endpoint path-rewrite behavior against the k3s registry docs for your version.

## GKE / managed nodes

GKE nodes pull the upstream origins directly — **no node-level redirect is needed or wanted** here. The containerd-can't-pull-without-a-redirect problem is a kind-only quirk (kind's node image ships `config_path` wired for `certs.d`); GKE's stock containerd has no such gap, so wiring a privileged DaemonSet to rewrite `certs.d`/`hosts.toml` on every node would just add a central-Harbor bootstrap self-dependency for no benefit.

Where you *do* want the proxy-cache used on GKE, pin the stack's own image references to `harbor.<domain>` at the manifest level (i.e. point the workload's `image:` at the Harbor-fronted path) instead of redirecting the node runtime.

## Windows / Git Bash

`docker exec`/`docker cp` rewrite in-container absolute paths like `/etc/containerd/certs.d/...` into `C:/Program Files/Git/etc/...` (MSYS path conversion), so the manual commands fail with "No such file or directory". Prefix them with `MSYS_NO_PATHCONV=1` (the helper script does this) or wrap the in-container command in `sh -c '...'`.
