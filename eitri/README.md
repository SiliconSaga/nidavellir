# Eitri — Software-Factory Sub-Component

Eitri is Nidavellir's home for CI/CD, build, and artifact tooling. It sits alongside **Vegvísir** (platform routing): where Vegvísir wayfinds traffic, Eitri forges and caches the ecosystem's artifacts. Named for the master dwarf-smith of Norse myth who forged the gods' treasures in Niðavellir — apt for the realm whose parent component is named after the dwarves' forge.

## Tools

| Tool | Concern | Status |
|---|---|---|
| **Harbor** (`harbor/`) | OCI image registry + pull-through cache for the stack's upstreams (`xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io`) | in use — see `harbor/README.md` |
| Jenkins | CI / build orchestration | legacy on GKE (`jenkins` ns) — to formalize |
| Nexus / Artifactory | non-OCI artifacts (maven, npm, generic) | legacy on GKE — to formalize |
| Sonar | code quality / static analysis | legacy on GKE (`sonar` ns) — to formalize |

Harbor is the first tool brought under Eitri; the build tools already running unmanaged on the GKE cluster graduate here as they're formalized.

## Docs

- `docs/plans/2026-07-04-harbor-mirror-registry-design.md` — the mirror / pull-through-cache capability: topology, the two-tier containerd fallback chain, and how it rolls out across clusters.
