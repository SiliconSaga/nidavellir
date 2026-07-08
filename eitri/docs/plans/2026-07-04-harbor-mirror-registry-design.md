# Harbor Mirror Registry — Pull-Through Cache for the Stack

**Status:** Design · **Date:** 2026-07-04 · **Arc:** image-mirror-registry

## Context

The stack has no image proxy today: it pulls directly from `xpkg.crossplane.io` (Crossplane core), `xpkg.upbound.io` (providers/functions), `quay.io`, `ghcr.io`, and `docker.io`. This surfaced as a hard blocker during the nidavellir#20 local validation — a Docker-Desktop/kind cluster's node containerd fails to pull `xpkg.crossplane.io` (`short read … unexpected EOF`) while the host `docker` pulls the same image fine, so the bootstrap dies at Layer 2.5 (Crossplane Core). Beyond that specific substrate, the stack wants resilience against upstream outages/rate-limits and, eventually, its own registry. The existing git "vendor-mirror" model is unrelated — it mirrors upstream *repos* into seed-Gitea and cannot serve container images.

GCP context already in place: project `teralivekubernetes`, a real GKE cluster, Workload Identity, Cloud DNS on `cmdbee.org`, and cert-manager DNS-01. No Artifact Registry is wired in; the plan is a self-hosted **public-read Harbor** instead.

## Goals

- A self-hosted, **public-read** Harbor that **proxy-caches** every upstream the stack needs.
- A **fresh cluster (including Docker Desktop, with no auth)** can bootstrap Crossplane by pulling through it.
- A **fallback chain** — cluster-local Harbor → public GKE Harbor → origin — with images cached at each tier they pass through.
- Deployable per-cluster everywhere, rolled out **GKE-first**.

## Non-Goals

- Replacing the git vendor-mirror model (it stays; different job).
- Hosting the stack's own *built* images with auth/RBAC (future; this is proxy-cache first).
- GCP Artifact Registry (deliberately not chosen — self-hosted public-read Harbor instead, to keep local pulls auth-free).
- Image signing / Trivy scanning / retention policy (future hardening).

## Architecture

The fallback chain is realized at **two independent layers**.

**1. Availability fallback — containerd mirror ordering.** Each node's containerd is configured with an ordered list of mirror endpoints per upstream registry; it tries them in order and falls through on connection failure or 404:

```
pull xpkg.crossplane.io/crossplane/... →
  1. cluster-local Harbor    (in-cluster; fast; warm cache)      ── unreachable / miss ↓
  2. public GKE Harbor       (registry.cmdbee.org; shared cache) ── unreachable / miss ↓
  3. origin  (xpkg.crossplane.io, quay.io, ghcr.io, …)           (last resort)
```

**2. Caching — Harbor proxy-cache chaining.** The **cluster-local** Harbor is a proxy-cache whose upstream is the **GKE Harbor**; the **GKE** Harbor is a proxy-cache whose upstream is the **origin**. A cache miss fetches from the next tier up and caches on the way back, so both tiers warm automatically. This is the "when a local repo is available, images get cached there" behavior — it falls out of proxy-cache semantics, no extra machinery.

**Why this unblocks a fresh cluster:** a brand-new cluster has no local Harbor yet, so containerd endpoint #1 fails and it falls straight to #2 — the always-on **public-read** GKE Harbor — which pulls the image through (its containerd/registry can reach the origins fine) and caches it. No auth is needed because the GKE Harbor is public-read. Once the new cluster later deploys its own Harbor, endpoint #1 starts serving and warming locally.

## Components

- **`harbor` component** — the Harbor Helm chart, per-cluster deployable. Owns the Harbor install + its proxy-cache project definitions.
- **GKE Harbor (the load-bearing instance)** — public-read, stable hostname `registry.cmdbee.org` (existing Cloud DNS + cert-manager cert), with one proxy-cache project per origin: `crossplane` → `xpkg.crossplane.io`, `upbound` → `xpkg.upbound.io`, `quay` → `quay.io`, `ghcr` → `ghcr.io`, `dockerhub` → `docker.io`.
- **Per-cluster Harbor** — same chart; proxy-cache projects whose upstream is the GKE Harbor (chaining), not the origins directly.
- **containerd mirror config injection** — writes the per-node ordered-endpoint config. This is substrate-specific (see below) and is a **bootstrap-time / nordri concern**, because the mirror config must exist *before* ArgoCD/Crossplane pull anything — whereas the Harbor *apps* deploy via ArgoCD after a cluster is up. That split matters: Harbor-the-service is platform-tier; the mirror-config-that-points-at-it is Tier-1/bootstrap.

## The substrate wrinkle (the bulk of the work)

The mirror config lands differently on each substrate:

- **k3s (homelab Rancher Desktop / Idunn):** `/etc/rancher/k3s/registries.yaml` — k3s reads it natively; supports ordered `endpoint` lists per mirror.
- **kind / Docker Desktop:** `hosts.toml` under `/etc/containerd/certs.d/<registry>/` written *into the node container* (no k3s convenience). For Docker Desktop specifically this is the piece that unblocks it.
- **GKE:** node containerd config via a privileged DaemonSet (or node-bootstrap script) that writes `hosts.toml` on each node.

A small, substrate-aware helper (a DaemonSet that writes `hosts.toml`, or a bootstrap step) is the reusable mechanism.

## Rollout

1. **GKE Harbor** — stand it up public-read with the five origin proxy-cache projects. This is the load-bearing piece; nothing else works without it.
2. **Unblock Docker Desktop** — write containerd `hosts.toml` pointing `[GKE Harbor → origin]` for the xpkg registries (at minimum), re-run `bootstrap.sh homelab realm-siliconsaga`, and confirm Crossplane pulls through the GKE Harbor → the nidavellir#20 e2e completes on Docker Desktop with no auth.
3. **Everywhere** — package the `harbor` component + the containerd-config mechanism so per-cluster Harbors deploy via ArgoCD and the full three-tier chain is wired on all clusters.

## Testing

- Pull an `xpkg.crossplane.io/...` image through the GKE Harbor from Docker Desktop → succeeds and the GKE proxy-cache project shows the cached artifact.
- Fallback: stop the local Harbor endpoint → pull falls through to GKE; block GKE → falls through to origin.
- End-to-end: a fresh `bootstrap.sh homelab realm-siliconsaga` on Docker Desktop completes Layer 2.5+ (the original failure point).

## Open Questions / Risks

- **Harbor is heavy** (core, registry, database, redis, jobservice, portal). GKE resource footprint + per-cluster cost — a lighter proxy-only registry (e.g. Zot with sync, or `distribution` proxy mode) is a fallback if Harbor is too much; Harbor chosen for the multi-project proxy-cache UX and the eventual own-registry path.
- **Public-read exposure:** the GKE Harbor serves cached *public* upstream images publicly — acceptable, but consider basic abuse/rate protection (it's an open proxy to public registries; scope to known clusters or add a light gate if it draws traffic).
- **OCI artifacts:** Crossplane packages (`xpkg.*`) are OCI *artifacts*, not just container images — confirm Harbor proxy-cache passes their media types through (Harbor supports OCI; verify against `xpkg.crossplane.io` specifically, since that's the exact failing case).
- **TLS:** GKE Harbor must be HTTPS (cert-manager); in-cluster local Harbor can be HTTP over the cluster network, which simplifies the local `hosts.toml`.
- **Cost vs. #20 unblock:** step 1+2 alone unblock the immediate need; step 3 (everywhere) is the fuller capability and can follow once the GKE instance proves out.

## References

- `image-mirror-registry` arc (Nano76Win11 thalamus) — motivation + survey conclusions.
- nidavellir#20 local-validation failure (Docker-Desktop/kind containerd vs `xpkg.crossplane.io`).
- `components/nordri/platform/fundamentals/manifests/crossplane-providers.yaml` (`xpkg.upbound.io` pins) + `platform/fundamentals/apps/crossplane.yaml` (`charts.crossplane.io`, core images from `xpkg.crossplane.io`).
- Existing GCP: `components/nordri/gke-provision.sh`, `components/nordri/envs/gke/values.yaml` (project `teralivekubernetes`, `cmdbee.org`, Workload Identity).
