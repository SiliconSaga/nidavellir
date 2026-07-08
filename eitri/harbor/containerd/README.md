# containerd registry mirrors (client config)

These `hosts.toml` files point a cluster's node containerd at the public Harbor proxy-cache instead of pulling the failing upstreams directly. They are CLIENT config — applied per node, per substrate — separate from Harbor itself. Each installs at `/etc/containerd/certs.d/<upstream>/hosts.toml`.

## Docker Desktop / kind (the immediate #20 unblock)

The kind nodes are Docker containers (`desktop-control-plane`, `desktop-worker`). For each node and each upstream:

```
docker exec <node> mkdir -p /etc/containerd/certs.d/xpkg.crossplane.io
docker cp xpkg.crossplane.io.hosts.toml <node>:/etc/containerd/certs.d/xpkg.crossplane.io/hosts.toml
# repeat for xpkg.upbound.io
```

Confirm containerd reads `certs.d` (`config_path = "/etc/containerd/certs.d"` under the CRI registry section):

```
docker exec <node> grep -n 'config_path' /etc/containerd/config.toml
```

If it's missing, add it and restart containerd in the node. Then force a re-pull (delete the stuck pods so kubelet retries):

```
kubectl delete pod -n crossplane --all
```

## k3s (homelab Rancher Desktop / Idunn) — phase 3

k3s reads `/etc/rancher/k3s/registries.yaml` (an ordered `endpoint` list per mirror), not `certs.d`. Translate the same mapping there. Deferred to the phase-3 rollout.

## GKE nodes — phase 3

Node containerd config via a privileged DaemonSet that writes `certs.d` on each node. Deferred to phase-3.
