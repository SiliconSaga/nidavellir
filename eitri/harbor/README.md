# Harbor — pull-through cache

Public-read Harbor, fronted by the shared Traefik Gateway, proxy-caching the stack's upstream registries (`xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io`). A cluster whose container runtime can't reach an upstream directly — or that just wants insulation from upstream outages/rate-limits — pulls through Harbor instead, with no registry auth (the projects are public-read).

Files here:
- `values.yaml` — Harbor Helm values (clusterIP, trimmed to proxy-cache only — no Trivy/Notary/metrics).
- `httproute.yaml` — Gateway-API route exposing Harbor on the shared Traefik Gateway.
- `setup-proxy-cache.sh` — creates the public proxy-cache projects (one per upstream) via the Harbor API.
- `containerd/` — client-side mirror config to point a cluster's nodes at Harbor (see `containerd/README.md`).

## Deploy

Prerequisites: a kubectl/helm context for the target cluster; a `*.<domain>` wildcard DNS + cert that already covers `harbor.<domain>` (so there's no per-host DNS or cert step); and an admin password in the workspace `.env` (`HARBOR_ADMIN_PW`, gitignored). This instance runs on the GKE cluster `ttf-cluster` at `harbor.cmdbee.org`.

1. Namespace: `ws k8s create namespace harbor`
2. Chart repo: `helm repo add harbor https://helm.goharbor.io` then `helm repo update`
3. Install (`--set-string` so special characters in the password pass literally):
   `helm --kube-context <ctx> upgrade --install harbor harbor/harbor -n harbor -f values.yaml --set-string harborAdminPassword="$HARBOR_ADMIN_PW"`
4. Wait for pods: `ws k8s get pods -n harbor` (core / registry / database / redis / jobservice / portal / nginx Ready).
5. Confirm the front Service name: `ws k8s get svc -n harbor` → `harbor` (port 80); if different, fix `httproute.yaml`'s backendRef.
6. Expose: `ws k8s apply -f httproute.yaml`
7. Verify: `curl -fsS https://harbor.cmdbee.org/api/v2.0/health` → `"status":"healthy"`.
8. Proxy-cache projects: `HARBOR_ADMIN_PW=<pw> bash setup-proxy-cache.sh`
9. Verify a pull-through: `docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4` → succeeds (Harbor fetches it from `xpkg.crossplane.io` and caches it).

Point client clusters at the cache via `containerd/README.md`.

## How it works

- **Exposure:** Harbor runs as `clusterIP` and its own nginx front proxy handles `/v2/`, `/api/`, `/`; the shared Traefik Gateway routes `harbor.<domain>` to it via `httproute.yaml`. TLS terminates at the Gateway on the `*.<domain>` wildcard cert, so Harbor itself speaks plain HTTP inside the cluster.
- **Proxy-cache:** each upstream is a Harbor *registry endpoint* plus a *public project* in proxy-cache mode. A pull to `harbor.<domain>/<project>/<repo>` is served from cache, or fetched from the origin and cached on the way through. Anonymous pull works because the projects are public.
- **Hostname is instance config.** `values.yaml` (`externalURL`), `httproute.yaml` (hostname), and the `containerd/` `hosts.toml` all name this instance's `harbor.cmdbee.org`; a different instance changes those three in step.
- **Admin password** lives in the workspace `.env` (gitignored) and, after install, in the `harbor-core` secret — never in git.
- Deployed here as a direct `helm install`.
