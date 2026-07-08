# Eitri — Software-Factory Sub-Component

Eitri is Nidavellir's home for CI/CD, build, and artifact tooling — the smith who forges and stores the ecosystem's artifacts. It sits alongside **Vegvísir** (platform routing): where Vegvísir wayfinds traffic, Eitri forges and caches artifacts.

Named for the master dwarf-smith of Norse myth (brother of Brokkr) who forged the gods' treasures in Niðavellir — and, fittingly, Stormbreaker in the MCU. Apt for the realm whose parent component is named after the dwarves' forge.

## Tools

| Tool | Concern | Status |
|---|---|---|
| **Harbor** (`harbor/`) | OCI image registry + pull-through cache for the stack's upstreams (`xpkg.crossplane.io`, `xpkg.upbound.io`, quay, ghcr, docker.io) | Phase 1–2 — see `harbor/README.md` |
| Jenkins | CI / build orchestration | legacy on GKE (`jenkins` ns) — to formalize |
| Nexus / Artifactory | non-OCI artifacts (maven, npm, generic) | legacy on GKE — to formalize |
| Sonar | code quality / static analysis | legacy on GKE (`sonar` ns) — to formalize |

Harbor is the first tool brought under Eitri. The build tools already running (unmanaged) on the GKE cluster graduate here as they're formalized.

## Docs

- `docs/plans/2026-07-04-harbor-mirror-registry-design.md` — the mirror / pull-through-cache capability (topology, the containerd fallback chain, GKE-first rollout).
- `docs/plans/2026-07-04-harbor-mirror-registry-plan.md` — implementation plan (phases 0–2).
