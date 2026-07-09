# Harbor as a Stack Member — Design

**Status:** Design · **Date:** 2026-07-08

## Context

Harbor currently ships as a direct `helm install` on one GKE cluster, with the hostname (`harbor.cmdbee.org`), storageClass (`standard-rwo`), and the chart's bundled Postgres + Redis all baked into `values.yaml`. That makes it GKE/`cmdbee`-specific and the odd one out among the stack's environment-aware apps: openbao and ntfy render `storageClass` + `domain` from the `cluster-identity` `EnvironmentConfig` (via `function-environment-configs`), and keycloak vends its Postgres from Mimir (a Percona `PostgreSQLInstance` claim) rather than bundling one.

This design graduates Harbor into a full, GitOps-managed stack member: a Crossplane composition, environment-aware through cluster-identity, with data stores vended from Mimir, deployed across clusters as a **central + local pull-through mesh**.

## Goals

- Harbor deployed and managed like the stack's other env-aware apps (composition + cluster-identity + ArgoCD), not a hand-run helm install.
- Nothing hardcoded: hostname, storageClass, and data stores are all environment-derived.
- A central/local fallback mesh: one always-on public-read **central** hub plus **local** caches on durable clusters, chaining `local → central → origin`.
- Auth-less fresh-cluster bootstrap still works: a new cluster pulls Crossplane through the central hub with no credentials.

## Non-Goals

- Per-cluster Harbor on ephemeral/constrained dev clusters (kind / Docker Desktop) — they pull from central directly, never run their own instance.
- Harbor as an authenticated own-registry (push), image signing, or vulnerability scanning — this is proxy-cache only, as today.
- Migrating cached data between the old and new instances — a proxy-cache has no precious state; instances re-warm on demand.

## Instance roles + the fallback chain

A single `Harbor` XRD/composition renders one of two roles, selected per-cluster from cluster-identity (below):

- **`central`** — the always-on, public-read hub. One per ecosystem, on the designated platform cluster (GKE today). Its proxy-cache projects target the **origins** (`xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io`). Public-read (anonymous pull) so auth-less clusters and fresh bootstraps pull with no credentials. This is the load-bearing instance every other cluster leans on. The hub's `central` instance doubles as that cluster's own local cache — no separate local there.
- **`local`** — on other **durable** clusters (e.g. homelab k3s). Same chart, but its proxy-cache projects target the **central Harbor's URL** (chaining) rather than the origins. A miss fetches from central (warming it too), or from origin if central is unreachable.

Ephemeral/constrained dev clusters (kind / Docker Desktop) run **no** Harbor; they point straight at central. So the chain is `cluster-local → central → origin`, collapsing to `central → origin` where there is no local.

## cluster-identity extension

`cluster-identity` is the per-environment `EnvironmentConfig` the compositions already read for `storageClass` + `domain`. Harbor's role belongs there too — it is part of "what this cluster is" — so the composition reads it the same way, with no per-cluster claim divergence. Extend the `data`:

```yaml
# gke (central)
data:
  environment: gke
  storageClass: standard-rwo
  domain: cmdbee.org
  harborRole: central          # proxy-cache the origins; its own URL is harbor.<domain>
```
```yaml
# homelab (local)
data:
  environment: homelab
  storageClass: local-path
  domain: homelab.local
  harborRole: local
  harborCentral: harbor.cmdbee.org   # the hub's hostname (on the central's domain, not this cluster's)
```

A `local` instance needs `harborCentral` because the hub lives on a different domain than the local cluster's own `domain`. `central` needs no `harborCentral` (it proxies origins).

*Alternative considered:* keep `cluster-identity` strictly generic and put `harborRole`/`harborCentral` in a separate eitri-owned `EnvironmentConfig` loaded alongside (`function-environment-configs` accepts several). Rejected for simplicity — a cluster's cache role reads as identity, and one object is easier to reason about.

## The composition (Tier-2, `eitri/harbor/`)

Mirrors the openbao/ntfy pattern:

- **`function-environment-configs`** loads `cluster-identity` → `domain`, `storageClass`, `harborRole`, `harborCentral`.
- **`function-go-templating`** renders, from those values:
  - the Harbor Helm **`Release`** (values templated: `externalURL: https://harbor.{{ .domain }}`, every PVC `storageClass: {{ .storageClass }}`, `expose.type: clusterIP`, trimmed of Trivy/Notary/metrics);
  - the **`HTTPRoute`** on the shared Traefik Gateway for `harbor.{{ .domain }}`;
  - the **proxy-cache project setup** — the current `setup-proxy-cache.sh` logic, driven by `harborRole`: `central` creates one project per origin, `local` creates the mirror projects pointed at `harborCentral`.
- **Data stores vended from Mimir**, like keycloak:
  - a Percona **`PostgreSQLInstance`** claim for the DB;
  - a **valkey** instance (valkey-operator) for Redis;
  - the Harbor chart runs with `database.type: external` + `redis.type: external` pointing at the vended Services (and their generated user secrets). No bundled Postgres/Redis, no hardcoded storageClass.
- **GitOps:** a Harbor ArgoCD Application in the nidavellir app-of-apps. Every durable cluster's ArgoCD deploys its Harbor instance; the role comes from that cluster's cluster-identity (`central` on the hub, `local` elsewhere). Ordered **after Mimir** (the DB claim needs the Percona operator + CRDs present) via the same sync-wave / CRD-retry the keycloak-after-Mimir path uses.

## Client redirect — per substrate

How a node/workload is pointed at Harbor differs by substrate; the mapping (`xpkg.crossplane.io` → `harbor.<domain>/v2/crossplane`, etc.) is identical everywhere.

- **kind / Docker Desktop** (ephemeral): node `certs.d` `hosts.toml` → **central** (no local exists). Bootstrap-time; `wire-containerd-kind.sh` already installs it. Required — kind's containerd can't reach the origins directly.
- **homelab k3s** (durable, `local`): `/etc/rancher/k3s/registries.yaml` with **ordered** mirror endpoints `local → central → origin`. Bootstrap-time; during bootstrap the local isn't up yet so it falls through to central, then serves locally once its instance is Running. k3s does ordered endpoints natively.
- **GKE**: **no node redirect** — GKE nodes pull the origins fine (the containerd-can't-pull failure is a kind/Docker-Desktop quirk, not a GKE one). Where the cache is wanted on GKE, pin the stack's own image refs to `harbor.<domain>` at the manifest level; otherwise pull origins directly. The GKE/central instance's main job is serving every other cluster.
- **Stack's own images (any cluster, manifest-level)**: optionally pin controlled image refs (e.g. `crossplane-providers.yaml`) to `harbor.<domain>/...` — a redirect that needs no node access, the clean path for images the stack owns.

## Tiers — who owns what

- **Tier-1 (nordri / bootstrap):** `cluster-identity` (now including `harborRole`/`harborCentral`) declares the cluster's role. The pre-pull client redirect (kind `certs.d`, k3s `registries.yaml`), pointed at central, must exist before the runtime pulls anything. The central Harbor is an external prerequisite for any fresh bootstrap.
- **Tier-2 (nidavellir / eitri):** the Harbor composition (central + local instances), GitOps-managed, ordered after Mimir; the Mimir-vended Postgres + valkey; the proxy-cache project setup.
- **The hub:** the designated central cluster's always-on public-read Harbor — the single dependency fresh bootstraps rely on.

## Bootstrap ordering + migration

- **The central has no self-dependency.** It lives on the GKE hub, whose nodes pull origins directly, so it bootstraps by pulling its own chart/images from upstream — no Harbor is needed to bring up Harbor. Once Running, it serves everyone.
- **Fresh-cluster ordering.** A new cluster's client redirect points at **central**, so it pulls Crossplane and the platform through central (no local yet). After Crossplane / ArgoCD / **Mimir** are up, the cluster's Tier-2 Harbor composition deploys its `local` instance; the DB claim resolves once Percona is up (sync-wave / CRD-retry ordering, same as keycloak-after-Mimir). Once local is Running, the ordered endpoints prefer it.
- **Migration from the current direct-install.** The live `cmdbee` Harbor is a direct `helm install` with bundled DB + hardcoded values. Because a proxy-cache has **no precious state** (cached blobs re-warm on demand), the clean path is **reinstall, not adopt**: tear down the direct release, let the composition redeploy it as `harborRole: central` with cluster-identity `domain` + Mimir-vended Postgres/valkey. Zero data loss, no bundled→vended DB migration.

## Testing

- **Offline render** (openbao's `tests/render/` pattern): `crossplane render` the Harbor XR against `gke` + `homelab` cluster-identity fixtures → assert `central` renders origin-targeted projects at `harbor.cmdbee.org`, `local` renders central-targeted projects at `harbor.homelab.local`, correct `storageClass`, and external DB/Redis refs. Catches the env-seams without a cluster.
- **kuttl (live):** the instance reaches Ready (composition → Release → pods); the proxy-cache projects exist; a real pull-through returns a digest; the vended Percona / valkey claims resolve (Services + user secrets present).
- **Client-redirect smoke:** the existing `wire-containerd-kind.sh` pull-through for the kind path; a k3s `registries.yaml` equivalent for homelab.

## Open questions / risks

- **Harbor chart + external Redis/valkey.** Confirm the Harbor chart's `redis.type: external` accepts a valkey endpoint (valkey is Redis-protocol-compatible, but the chart's expectations — e.g. sentinel vs standalone, auth — need verifying against the vended valkey shape).
- **Central URL discovery for `local`.** `harborCentral` is set literally in the local cluster's cluster-identity. If the hub's hostname ever changes, that's a manual edit on each local cluster — acceptable given how rarely it moves; revisit if instances proliferate.
- **Mimir dependency on the hub.** The `central` instance also vends its DB from Mimir, so the hub cluster must run Mimir before Harbor — already true (the hub runs the full stack), but the ordering must be explicit in the app-of-apps.
- **Reinstall window.** Tearing down the live central to redeploy as a composition briefly removes the shared cache; any cluster mid-bootstrap during that window falls through to origins (fine for GKE/homelab, but a kind cluster mid-bootstrap would stall). Do the migration when nothing is bootstrapping.
