# Harbor Mirror Registry — Pull-Through Cache for the Stack

**Status:** Design · **Date:** 2026-07-04

## Context

The stack pulls container images directly from several upstream registries with no proxy in front of them: `xpkg.crossplane.io` (Crossplane core), `xpkg.upbound.io` (providers/functions), `quay.io`, `ghcr.io`, and `docker.io`. Two problems follow. First, some clusters' container runtimes cannot pull from certain upstreams at all — e.g. containerd on a kind-based node fails to pull `xpkg.crossplane.io` (`short read … unexpected EOF`) while the host `docker` daemon pulls the same image fine — which blocks any workload that needs those images. Second, direct upstream pulls expose every cluster to upstream outages and rate-limits.

A self-hosted, **public-read pull-through cache** (Harbor) addresses both: it proxies and caches the upstreams, a runtime that can't reach an origin can reach the cache instead, and repeated pulls are served from cache rather than the internet. (The stack's existing git "vendor-mirror" model is unrelated — it mirrors upstream *repos* into an in-cluster Gitea and cannot serve container images.)

The first instance runs on an existing GKE cluster with Cloud DNS and cert-manager already in place; additional instances on other clusters or domains follow the same pattern.

## Goals

- A self-hosted, **public-read** Harbor that **proxy-caches** every upstream the stack needs.
- A cluster **with no registry credentials** can pull through it (public-read → no auth).
- A **fallback chain** — cluster-local Harbor → central public Harbor → origin — with images cached at each tier they pass through.
- Deployable per-cluster; rolled out **central-instance-first**.

## Non-Goals

- Replacing the git vendor-mirror model (it stays; different job).
- Hosting the stack's own *built* images with auth/RBAC (future; this is proxy-cache first).
- A managed cloud registry as the mirror (deliberately self-hosted public-read Harbor instead, to keep client pulls auth-free).
- Image signing / vulnerability scanning / retention policy (future hardening).

## Architecture

The fallback chain is realized at **two independent layers**.

**1. Availability fallback — containerd mirror ordering.** Each node's containerd is configured with an ordered list of mirror endpoints per upstream registry; it tries them in order and falls through on connection failure or 404:

```
pull xpkg.crossplane.io/crossplane/... →
  1. cluster-local Harbor    (in-cluster; fast; warm cache)     ── unreachable / miss ↓
  2. central public Harbor   (harbor.<domain>; shared cache)    ── unreachable / miss ↓
  3. origin  (xpkg.crossplane.io, quay.io, ghcr.io, …)          (last resort)
```

**2. Caching — Harbor proxy-cache chaining.** The **cluster-local** Harbor is a proxy-cache whose upstream is the **central public Harbor**; the **central** Harbor is a proxy-cache whose upstream is the **origin**. A cache miss fetches from the next tier up and caches on the way back, so both tiers warm automatically. This "when a local repo is available, images cache there" behavior falls out of proxy-cache semantics — no extra machinery.

**Why this serves a fresh cluster:** a brand-new cluster has no local Harbor yet, so containerd endpoint #1 fails and it falls straight to #2 — the always-on **public-read** central Harbor — which pulls the image through (its own runtime can reach the origins) and caches it. No auth is needed because that instance is public-read. Once the new cluster later deploys its own Harbor, endpoint #1 starts serving and warming locally.

## Components

- **Harbor Helm deployment** — per-cluster deployable; owns the Harbor install + its proxy-cache project definitions.
- **The central public instance** — public-read, at a stable hostname `harbor.<domain>`, with one proxy-cache project per origin: `crossplane` → `xpkg.crossplane.io`, `upbound` → `xpkg.upbound.io`, `quay` → `quay.io`, `ghcr` → `ghcr.io`, `dockerhub` → `docker.io`. It is the load-bearing instance — every other cluster and any fresh cluster relies on it.
- **Per-cluster instances** — same chart; proxy-cache projects whose upstream is the central Harbor (chaining), not the origins directly.
- **containerd mirror config injection** — writes the per-node ordered-endpoint config. It must exist *before* a runtime pulls anything (i.e. at cluster bootstrap, a substrate/Tier-1 concern), whereas the Harbor *service* deploys after a cluster is up (platform-tier). That split matters: Harbor-the-service is platform-tier; the mirror-config-that-points-at-it is bootstrap-time.

## The substrate wrinkle (the bulk of the work)

The mirror config lands differently on each substrate:

- **k3s (e.g. homelab Rancher Desktop):** `/etc/rancher/k3s/registries.yaml` — k3s reads it natively; supports ordered `endpoint` lists per mirror.
- **kind / Docker Desktop:** `hosts.toml` under `/etc/containerd/certs.d/<registry>/` written *into the node container* (no k3s convenience).
- **Managed (e.g. GKE):** node containerd config via a privileged DaemonSet (or node-bootstrap script) that writes `hosts.toml` on each node.

A small, substrate-aware helper (a DaemonSet that writes `hosts.toml`, or a bootstrap step) is the reusable mechanism.

## Rollout

1. **Central public instance** — stand it up public-read with the origin proxy-cache projects. Nothing else works without it.
2. **Wire a client cluster** — write the containerd `hosts.toml` pointing `[central Harbor → origin]` for the needed registries and confirm a runtime that previously couldn't pull those upstreams now resolves them through Harbor with no auth.
3. **Everywhere** — package the Harbor deployment + the containerd-config mechanism so per-cluster instances deploy via GitOps and the full three-tier chain is wired on all clusters.

## Testing

- Pull an `xpkg.crossplane.io/...` image through the central Harbor from a client → succeeds, and the proxy-cache project shows the cached artifact.
- Fallback: stop the local Harbor endpoint → pull falls through to the central one; block the central one → falls through to origin.
- A client whose runtime previously failed on a given upstream now pulls it successfully once its containerd is pointed at Harbor.

## Open Questions / Risks

- **Harbor is heavy** (core, registry, database, redis, jobservice, portal). Resource footprint per instance — a lighter proxy-only registry (e.g. Zot with sync, or `distribution` proxy mode) is a fallback if Harbor is too much; Harbor chosen for the multi-project proxy-cache UX and the eventual own-registry path.
- **Public-read exposure:** the central instance serves cached *public* upstream images publicly — acceptable, but consider basic abuse/rate protection (it's an open proxy to public registries; scope to known clients or add a light gate if it draws traffic).
- **OCI artifacts:** Crossplane packages (`xpkg.*`) are OCI *artifacts*, not just container images — confirm Harbor proxy-cache passes their media types through (Harbor supports OCI; verify against `xpkg.crossplane.io` specifically, since that is the exact upstream a kind-based runtime tends to fail on).
- **TLS:** the central instance must be HTTPS (cert-manager); an in-cluster local instance can be HTTP over the cluster network, which simplifies its `hosts.toml`.
- **Cost vs. immediate need:** the central instance alone covers the immediate need; the per-cluster/everywhere rollout is the fuller capability and can follow once the central instance proves out.

## References

- Sibling component **nordri** (not this repo): `platform/fundamentals/manifests/crossplane-providers.yaml` (`xpkg.upbound.io` pins) + `platform/fundamentals/apps/crossplane.yaml` (`charts.crossplane.io`; core images resolve from `xpkg.crossplane.io`) — where the stack's `xpkg.*` upstreams are declared.
- The container-runtime-vs-`xpkg.crossplane.io` pull failure (kind-based containerd `short read … unexpected EOF` where host docker succeeds) that motivated this capability.
