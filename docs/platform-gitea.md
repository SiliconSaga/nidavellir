# Platform Gitea — Design Notes

## Context

During bootstrap, Nordri installs a **Seed Gitea** — a minimal, ephemeral instance with
no persistent storage, using the Gitea chart's bundled Postgres and Valkey. Its only job
is to host the Nordri + Nidavellir repos so ArgoCD has a GitOps source.

Once Mimir is stable and vending data services, Gitea should be hardened into a proper
platform component with durable storage, TLS, and a real subdomain.

## Target State

| Concern | Seed Gitea (now) | Platform Gitea (target) |
|---|---|---|
| Postgres | Bundled chart dep | Mimir-vended (Crossplane/operator) |
| Valkey/Redis | Bundled chart dep | Mimir-vended |
| Persistence | `persistence.enabled=false` | PVC-backed repo storage |
| TLS | None (internal only) | cert-manager via Vegvísir |
| Subdomain | N/A | e.g. `gitea.<domain>` |
| Managed by | bootstrap.sh (Helm) | ArgoCD app in nidavellir/apps/ |

## Sequencing Problem

ArgoCD pulls from Seed Gitea throughout the whole platform lifecycle. The transition
to Platform Gitea must avoid a window where ArgoCD loses its GitOps source:

1. Push all repos to GitHub (use the existing "Transition to GitHub" flow in
   `vegvisir/README.md` — switch ArgoCD repoURLs to GitHub remote).
2. With ArgoCD no longer dependent on internal Gitea, deploy Platform Gitea as a
   normal Nidavellir app (backed by Mimir, with PVC, TLS, subdomain).
3. Migrate repo data from Seed → Platform Gitea (Gitea has a built-in admin migration
   API; or just re-push from local since repos are mirrored locally).
4. Optionally switch ArgoCD source back to internal Platform Gitea.

## Open Questions

- Do we want ArgoCD to pull from Platform Gitea long-term, or stay on GitHub?
  Internal Gitea = air-gapped capability + faster pulls; GitHub = simpler ops.
- What Mimir Postgres instance class / size for Gitea?
- Gitea admin credentials: move from bootstrap hardcoded values to OpenBAO.
