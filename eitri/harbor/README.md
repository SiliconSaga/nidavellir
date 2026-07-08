# Harbor pull-through cache — GKE deploy (phases 1–2)

Public-read Harbor on the durable GKE cluster (`ttf-cluster`, project `teralivekubernetes`), fronted by the shared Traefik Gateway at `harbor.cmdbee.org`, proxy-caching the stack's upstream registries. Unblocks auth-less clusters (Docker Desktop) whose containerd can't reach `xpkg.crossplane.io` directly.

First tool under the **Eitri** software-factory sub-component. Design: `../docs/plans/2026-07-04-harbor-mirror-registry-design.md` · Plan: `../docs/plans/2026-07-04-harbor-mirror-registry-plan.md`.

## Prereqs (done)

- gcloud authed, `gke-gcloud-auth-plugin` installed, credentials for `ttf-cluster`.
- `ws k8s` guard armed: context `gke_teralivekubernetes_us-east1-d_ttf-cluster`, ns `harbor`.
- `*.cmdbee.org` wildcard DNS (→ Traefik LB `34.75.13.183`) + wildcard cert already exist, so `harbor.cmdbee.org` resolves and gets TLS with no per-host action.

## Deploy (writes go through `ws k8s`; helm targets the GKE context)

1. Namespace: `ws k8s create namespace harbor`
2. Chart repo (two calls — no shell composition under the hook): `helm repo add harbor https://helm.goharbor.io` then `helm repo update`
3. Install (admin password from `.env` — `HARBOR_ADMIN_PW`, not committed):
   `helm --kube-context gke_teralivekubernetes_us-east1-d_ttf-cluster upgrade --install harbor harbor/harbor -n harbor -f values.yaml --set harborAdminPassword="$HARBOR_ADMIN_PW"`
4. Wait for pods: `ws k8s get pods -n harbor` (core / registry / database / redis / jobservice / portal / nginx Ready).
5. Confirm the front service name: `ws k8s get svc -n harbor` → expect `harbor` (port 80); if different, fix `httproute.yaml` backendRef.
6. Expose: `ws k8s apply -f httproute.yaml`
7. Verify TLS + reach: `curl -fsS https://harbor.cmdbee.org/api/v2.0/health` → `"status":"healthy"`.
8. Proxy-cache projects: `HARBOR_ADMIN_PW=<pw> bash setup-proxy-cache.sh`
9. Load-bearing verify (the exact image that failed on Docker Desktop): `docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4`

## Wire Docker Desktop (phase 2)

See `containerd/README.md` — copy the two `hosts.toml` into the kind nodes, then re-run `bootstrap.sh homelab realm-siliconsaga` (Crossplane now pulls via Harbor) and assert the #20 realm-injection e2e.

## Notes

- Deploy mechanism here is a **direct helm install** (prove-it-out). Graduating Harbor to an ArgoCD-managed app + per-cluster instances + k3s/GKE containerd wiring is the phase-3 "everywhere" follow-up.
- **Admin password** is generated into the workspace `.env` (gitignored, `HARBOR_ADMIN_PW`) and, post-install, lives in the `harbor-core` secret — never in git.
- Lives under `nidavellir/eitri/harbor/` — the Eitri software-factory sub-component, parallel to Vegvísir (routing).
