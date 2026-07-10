# Harbor — pull-through cache

Public-read Harbor, fronted by the shared Traefik Gateway, proxy-caching the stack's upstream registries (`xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io`). A cluster whose container runtime can't reach an upstream directly — or that just wants insulation from upstream outages/rate-limits — pulls through Harbor instead, with no registry auth (the projects are public-read).

Files here:
- `values.yaml` — Harbor Helm values (clusterIP, trimmed to proxy-cache only — no Trivy/Notary/metrics).
- `httproute.yaml` — Gateway-API route exposing Harbor on the shared Traefik Gateway.
- `setup-proxy-cache.sh` — creates the public proxy-cache projects (one per upstream) via the Harbor API.
- `containerd/` — client-side mirror config to point a cluster's nodes at Harbor (see `containerd/README.md`).

## Deploy

> **Current/interim path.** The steps below are a direct `helm upgrade --install`, run by hand outside Crossplane. Running them against a cluster that already has the `XHarbor` composition managing this namespace will create an unmanaged duplicate release — don't run both against the same cluster/namespace. The target deployment path is the `HarborInstance` claim (the namespaced claim for the `XHarbor` composite) + composition (`eitri/harbor/xrd.yaml` + `composition.yaml`), applied via GitOps in Phase 2; once that's wired up, this section will be superseded.

Prerequisites: a kubectl/helm context for the target cluster; a `*.<domain>` wildcard DNS + cert that already covers `harbor.<domain>` (so there's no per-host DNS or cert step); and an admin password in the workspace `.env` (`HARBOR_ADMIN_PW`, gitignored). `.env` isn't auto-exported into your shell — load it first (e.g. `set -a; source .env; set +a` from the workspace root, or export `HARBOR_ADMIN_PW` manually) before the commands below reference it. (Once the composition manages this instance, the admin secret instead comes from the externally-managed `harbor-admin` Secret — provisioned via ESO/OpenBao, and referenced by the chart via `existingSecretAdminPassword` — see the composition's `deploy-harbor` step. Because that setting is set, the chart skips writing the admin password into its own generated `harbor-core` Secret.) This instance runs on the GKE cluster `ttf-cluster` at `harbor.cmdbee.org`.

**All steps below run against your current kubectl context** — point it at the target cluster first (`kubectl config use-context <ctx>`; if you use the `ws k8s` guard, arm it on the same context), so the `helm` install and the `ws k8s` commands can't land on different clusters.

1. Namespace: `ws k8s create namespace harbor`
2. Chart repo: `helm repo add harbor https://helm.goharbor.io` then `helm repo update`
3. Install (`--set-string` so special characters in the password pass literally):
   `helm upgrade --install harbor harbor/harbor -n harbor -f values.yaml --set-string harborAdminPassword="$HARBOR_ADMIN_PW"` (targets the current context set above)
4. Wait for pods: `ws k8s get pods -n harbor` (core / registry / database / redis / jobservice / portal / nginx Ready).
5. Confirm the front Service name: `ws k8s get svc -n harbor` → `harbor` (port 80); if different, fix `httproute.yaml`'s backendRef.
6. Expose: `ws k8s apply -f httproute.yaml`
7. Verify: `curl -fsS https://harbor.cmdbee.org/api/v2.0/health` → `"status":"healthy"`.
8. Proxy-cache projects: `bash setup-proxy-cache.sh` (uses the `HARBOR_ADMIN_PW` you exported above)
9. Verify a pull-through: `docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4` → succeeds (Harbor fetches it from `xpkg.crossplane.io` and caches it).

Point client clusters at the cache via `containerd/README.md`.

## How it works

- **Exposure:** Harbor runs as `clusterIP` and its own nginx front proxy handles `/v2/`, `/api/`, `/`; the shared Traefik Gateway routes `harbor.<domain>` to it via `httproute.yaml`. TLS terminates at the Gateway on the `*.<domain>` wildcard cert, so Harbor itself speaks plain HTTP inside the cluster.
- **Proxy-cache:** each upstream is a Harbor *registry endpoint* plus a *public project* in proxy-cache mode. A pull to `harbor.<domain>/<project>/<repo>` is served from cache, or fetched from the origin and cached on the way through. Anonymous pull works because the projects are public.
- **Hostname is instance config.** `values.yaml` (`externalURL`), `httproute.yaml` (hostname), and the `containerd/` `hosts.toml` all name this instance's `harbor.cmdbee.org`; a different instance changes those three in step.
- **Admin password** lives in the workspace `.env` (gitignored) for this direct-`helm` path. Under the composition, it instead comes from the externally-managed `harbor-admin` Secret (ESO/OpenBao) — never in git.
- Deployed here as a direct `helm install`.
