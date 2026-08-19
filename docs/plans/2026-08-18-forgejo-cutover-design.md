# Retiring the seed Gitea: Forgejo cutover design

**Status:** design, not scheduled
**Date:** 2026-08-18

Planning only. Nothing here is implemented — Forgejo currently exists as a single `DataService` claim in `nidavellir/forgejo/dataservice.yaml` with no deployment behind it.

## What exists today, verified

The seed Gitea in namespace `gitea` is a **Deployment**, not a StatefulSet, and its `data` volume is an **`emptyDir`**:

```console
$ kubectl -n gitea get deployment gitea -o jsonpath='{.spec.template.spec.volumes[*].name}'
init config inline-config-sources temp data      # temp and data are both emptyDir {}
```

That single fact is the whole recurring failure. Every repository lives in that `emptyDir`, so **any pod replacement discards every repository**. The pod at time of writing was 6h21m old against a 95-day-old Deployment.

Postgres, meanwhile, is a 3-replica HA StatefulSet on real PVCs, joined by a 3-node Valkey cluster. So when repositories vanish, **the database survives and keeps insisting they exist**. The API then answers `500` rather than `404`, and hydration will not recreate a repository the API claims is already there. Recovery means deleting the stale records through the API before re-hydrating — which is why this keeps costing a manual intervention.

Worth naming: the bootstrap git host runs **seven pods**, three of them a Postgres HA cluster, to serve four repositories. It is itself an instance of the cluster-per-app pattern Mimir now exists to end.

Hydration comes from the **workstation's working tree**, not from GitHub:

```bash
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$NIDAVELLIR_GITEA_REPO" "Hydration for $TARGET"
```

This matters for everything below. The seed exists so unpushed local branches can be tested in-cluster. Any replacement has to keep that property or the development loop regresses.

Sixteen manifests across five repos point at `http://gitea-http.gitea.svc.cluster.local:3000`.

## Fix the bleeding first — this does not need Forgejo

**Giving the seed Gitea a PVC stops the resets today.** It is a Helm values change, independent of everything else in this document, and it does not need the operator, the shared cluster, or a migration.

Nothing in the Forgejo plan should be treated as a prerequisite for that. The two have been coupled in conversation because the resets are what makes Forgejo feel urgent, but the coupling is not real. Do the PVC first, then take the cutover at whatever pace it deserves.

## The cycle Forgejo introduces

Once Forgejo is the git host ArgoCD reads from, and Forgejo's database comes from Mimir's shared cluster, and Mimir is deployed by ArgoCD:

```
Forgejo ──needs──> shared PostgreSQL ──deployed by──> ArgoCD ──reads──> Forgejo
```

**This is not a bootstrap problem. It is a recovery problem.** Ordering on first boot works itself out through retries: Forgejo crash-loops until its Secret exists, then starts. The danger is later. If the shared Postgres is lost while the cluster is running, Forgejo cannot start, ArgoCD cannot fetch manifests, and **the repair for Postgres is in a repository that needs Postgres to serve it**.

The seed Gitea is what makes this safe today, precisely because it depends on nothing. Deleting it transfers that job to Forgejo — and Forgejo cannot hold it while also being a customer of the thing it would need to repair.

### The rule

> **The git host ArgoCD bootstraps from must not depend on anything ArgoCD manages.**

Every option below is a different way to satisfy that.

## Options

### A — Forgejo self-sufficient, on SQLite

Forgejo supports SQLite on a PVC. No Mimir dependency, no cycle, seed Gitea retires cleanly.

The cost is directly at odds with what was just built: **Forgejo is the DataService operator's first customer**, and this removes it. The operator would need a different proving ground — Ting, Keycloak and Harbor all currently run their own Percona clusters and are candidates for consolidation.

SQLite is adequate for a single-operator homelab. It is not adequate if Forgejo ever grows CI, many users, or Actions runners.

### B — Keep a demoted seed

Forgejo uses the shared cluster as designed. Seed Gitea survives with a PVC, shrinks to hosting only the recovery-critical repos, and everything else moves to Forgejo.

Safe and cheap, but it does not deliver what was asked: the seed does not go away. It becomes a small permanent fixture instead of a recurring problem.

### C — Move layer 0 into `bootstrap.sh`, then retire the seed ★ recommended

`bootstrap.sh` already applies things directly from the workstation without any git server — it Helm-installs Gitea and applies ArgoCD that way today. Extend that to a **layer 0** applied directly:

1. ArgoCD, Crossplane, Percona PG operator
2. Mimir's shared cluster and DataService operator (`kubectl apply -k`)
3. Forgejo, plus hydration of its repositories
4. The root app-of-apps, pointed at Forgejo

Layer 1 and above then run as GitOps from Forgejo, re-adopting the layer-0 objects so they stay managed.

This satisfies the rule without a permanent seed: **the bootstrapping git host becomes the workstation checkout itself**, which is where authority already lives. Forgejo keeps its shared database and stays the operator's first customer. Seed Gitea genuinely goes away.

The residual risk is honest and worth stating plainly: a mid-life loss of the shared Postgres still stops GitOps until someone runs the recovery path from a workstation. That is acceptable *if the path is tested*, and unacceptable if it is only believed to work.

### C+ — one link pinned externally, nearly free

`SiliconSaga/mimir` is **public** (`"private": false`), so ArgoCD can read `https://github.com/SiliconSaga/mimir.git` anonymously — no repository credentials, no secret to manage.

Pointing only Mimir's Applications at GitHub breaks the cycle at exactly one link:

```
Forgejo ──needs──> shared PostgreSQL ──deployed by──> ArgoCD ──reads──> GitHub
```

Now a Forgejo outage is self-healing: ArgoCD repairs Mimir from GitHub, Postgres returns, Forgejo starts, everything else resumes. One `repoURL` differs from the rest, and it is the one that matters.

The cost is that Mimir loses the local-branch testing loop — its manifests must be pushed to GitHub to reach the cluster. Given the branch protection now on `main`, that is a PR per change to Mimir's deployment. Worth it for the component that has to be repairable when nothing else is.

**Recommendation: C with C+ layered on it.** C removes the seed, C+ makes the removal survivable without relying on a human being available.

## Mirror direction is a real decision

"GitHub mirror links of some sort" resolves into two incompatible designs.

| | Forgejo → GitHub (push mirror) | GitHub → Forgejo (pull mirror) |
|---|---|---|
| Authority | Forgejo | GitHub |
| Forgejo repos writable | **yes** | **no — read-only** |
| Local-branch testing | works | **breaks** |
| Losing Forgejo means | GitHub has a recent copy | nothing lost |

**Pull mirroring is disqualified.** Mirrored repositories in Forgejo are read-only, which destroys the exact workflow the seed Gitea exists to provide.

So: **Forgejo authoritative, push-mirroring to GitHub.** GitHub becomes a continuously-updated backup and the recovery source for C+. Two consequences to accept — push mirrors replicate *all* branches, so in-cluster test branches will appear on GitHub, and each mirror needs a GitHub token stored in Forgejo.

## Preconditions for deleting the seed

Not a sequence — a gate. All of it true before `helm uninstall gitea`.

- [ ] Forgejo's repositories are on a **PVC**, verified by deleting the pod and confirming they survive
- [ ] Shared Postgres has an **offsite backup**. This is currently **not true** — the pgBackRest repo is a local PVC with no offsite copy, and consolidation means one failure now costs every tenant rather than one
- [ ] Push mirrors to GitHub verified for every repository, by checking GitHub after a Forgejo-side commit
- [ ] ArgoCD reads from Forgejo for at least one app, sustained, before any bulk migration
- [ ] All sixteen `repoURL`s migrated and syncing
- [ ] `bootstrap.sh` brings up layer 0 with **no in-cluster git**, tested on a scratch cluster
- [ ] The local-branch testing loop works against Forgejo
- [ ] Recovery rehearsed: delete the shared Postgres on a scratch cluster and recover

The second box is the one that blocks. **Deleting the seed while backups are local-only trades a recurring annoyance for a single point of failure with no undo.** The current failure loses repositories that are all mirrored on GitHub and reconstructible from a workstation. The post-consolidation failure loses every tenant's database at once.

## Phasing

| Phase | Work | Gated on |
|---|---|---|
| 0 | PVC for seed Gitea | nothing — do this first |
| 1 | Offsite backup for the shared cluster | Mimir Phase 2 |
| 2 | Forgejo deployment consuming its Secret | operator deployed |
| 3 | Push mirrors to GitHub | Forgejo up |
| 4 | Migrate tier-2 `repoURL`s, Mimir's to GitHub (C+) | 3 |
| 5 | Layer 0 in `bootstrap.sh`, tested on a scratch cluster | 4 |
| 6 | Retire seed Gitea | the whole gate above |

Phase 0 removes the urgency from everything after it. Phase 1 is the real prerequisite, and it is the one most likely to be skipped because nothing visibly breaks without it.

## Open questions

1. **Does Forgejo stay the operator's first customer?** Option C says yes. If A is ever preferred, Ting is the natural substitute.
2. **Where do Forgejo Actions runners live**, if adopted? The operator image currently builds on GitHub Actions, so a GitHub outage stops operator releases — minor today, less so if more builds move in-cluster.
3. **Does the seed Gitea's Postgres HA cluster and Valkey cluster get consolidated first?** Seven pods for a bootstrap host is the measles pattern, and retiring it removes them anyway — an argument for doing 0 cheaply rather than investing in it.
