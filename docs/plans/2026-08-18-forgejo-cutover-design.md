# Retiring the seed Gitea: Forgejo cutover design

**Status:** design, not scheduled
**Date:** 2026-08-18 · revised 2026-08-23

Planning only. Nothing here is implemented — Forgejo currently exists as a single `DataService` claim in `nidavellir/forgejo/dataservice.yaml` with no deployment behind it.

> **Revised 2026-08-23.** The first version of this document argued that Forgejo must not depend on Mimir, and recommended either SQLite or moving a "layer 0" into `bootstrap.sh`. That was wrong, and the section [Why the cycle is not real](#why-the-cycle-is-not-real) explains why. The correction is kept rather than deleted because the reasoning error is instructive.

## What exists today, verified

The seed Gitea in namespace `gitea` is a **Deployment**, not a StatefulSet, and its `data` volume is an **`emptyDir`**:

```console
$ kubectl -n gitea get deployment gitea -o jsonpath='{.spec.template.spec.volumes[*].name}'
init config inline-config-sources temp data      # temp and data are both emptyDir {}
```

That single fact is the whole recurring failure. Every repository lives in that `emptyDir`, so **any pod replacement discards every repository**. The pod at time of writing was 6h21m old against a 95-day-old Deployment.

Postgres, meanwhile, is a 3-replica HA StatefulSet on real PVCs, joined by a 3-node Valkey cluster. So when repositories vanish, **the database survives and keeps insisting they exist**. The API then answers `500` rather than `404`, and hydration will not recreate a repository the API claims is already there. Recovery means deleting the stale records through the API before re-hydrating — which is why this keeps costing a manual intervention.

Worth naming: the bootstrap git host runs **seven pods**, three of them a Postgres HA cluster, to serve four repositories. Since the seed is meant to be discarded, that is an argument for fixing it cheaply rather than investing in it.

Hydration comes from the **workstation's working tree**, not from GitHub:

```bash
hydrate_working_tree_repo "$NIDAVELLIR_DIR" "$NIDAVELLIR_GITEA_REPO" "Hydration for $TARGET"
```

The seed exists so unpushed local branches can be tested in-cluster. Any replacement has to keep that property or the development loop regresses.

Sixteen manifests across five repos point at `http://gitea-http.gitea.svc.cluster.local:3000`.

## Fix the bleeding first — this does not need Forgejo

**Giving the seed Gitea a PVC stops the resets today.** It is a Helm values change, independent of everything else in this document, and it does not need the operator, the shared cluster, or a migration.

The two have been coupled in conversation because the resets are what make Forgejo feel urgent, but the coupling is not real. Do the PVC first, then take the cutover at whatever pace it deserves.

## The intended lifecycle

The seed is **ephemeral by design**, and crystallises into Forgejo once the platform is up:

1. `bootstrap.sh` stands up the seed Gitea from the workstation checkout and hydrates it.
2. ArgoCD syncs the platform from the seed — **including Mimir**, which comes up at wave 6 like everything else and is then available to process claims.
3. Once the platform is stable, Forgejo is deployed — a later sync wave, or an ad-hoc crystallisation step. It is an ordinary Mimir customer and gets its database the same way any app does.
4. Forgejo boots **empty, with nothing pointing at it**.
5. A hydration step fills it from Gitea or GitHub.
6. Platform `repoURL`s are re-pointed at Forgejo, everything resyncs, and the seed becomes vestigial.

The current awkwardness is only that we are still *in* step 1–2 while building step 3, and losing repositories in the meantime.

## Why the cycle is not real

The concern was: Forgejo needs the shared Postgres → which ArgoCD deploys → which reads Forgejo. A loop, and therefore a cluster that cannot repair itself.

**Forgejo is never on the bootstrap path, so the loop never closes during bring-up.** Mimir is already running long before Forgejo exists, because Mimir is deployed from the seed like every other platform component.

And after crystallisation, if the shared Postgres is lost, the recovery is **re-running the ephemeral bootstrap** — which needs no in-cluster git at all, only the workstation checkout. That is exactly what an ephemeral bootstrap is for. It is not a fixture that must be preserved; it is a procedure that can be re-run.

The original error was treating "the seed goes away" as "the seed can never exist again", which turned an ordinary recovery procedure into an architectural impossibility, and from there argued Forgejo into needing SQLite. Rejected:

- **Forgejo on SQLite** solves a problem that does not exist, and costs the operator a customer.
- **A permanent demoted seed** contradicts the point of an ephemeral bootstrap.
- **Pinning Mimir's Applications to GitHub** was a workaround for the same non-problem. (It remains *available* — `SiliconSaga/mimir` is public, so ArgoCD can read it anonymously with no credentials — but it is not needed, and it would cost Mimir the local-branch testing loop.)

**Forgejo is an ordinary Mimir customer.** Whether it or the new MySQL component is the first one is a race, not a decision.

## Mirror direction is a real decision

"GitHub mirror links of some sort" resolves into two incompatible designs.

| | Forgejo → GitHub (push mirror) | GitHub → Forgejo (pull mirror) |
|---|---|---|
| Authority | Forgejo | GitHub |
| Forgejo repos writable | **yes** | **no — read-only** |
| Local-branch testing | works | **breaks** |
| Losing Forgejo means | GitHub has a recent copy | nothing lost |

**Pull mirroring is disqualified.** Mirrored repositories in Forgejo are read-only, which destroys the exact workflow the seed exists to provide.

So: **Forgejo authoritative, push-mirroring to GitHub.** Two consequences to accept — push mirrors replicate *all* branches, so in-cluster test branches will appear on GitHub, and each mirror needs a GitHub token stored in Forgejo.

## Preconditions for retiring the seed

Not a sequence — a gate. All of it true before `helm uninstall gitea`.

- [ ] Forgejo's repositories are on a **PVC**, verified by deleting the pod and confirming they survive
- [ ] Shared Postgres has an **offsite backup**. Scheduling and retention now exist, but repo1 is still a local PVC with no offsite copy
- [ ] Push mirrors to GitHub verified for every repository, by checking GitHub after a Forgejo-side commit
- [ ] ArgoCD reads from Forgejo for at least one app, sustained, before any bulk migration
- [ ] All sixteen `repoURL`s migrated and syncing
- [ ] The local-branch testing loop works against Forgejo
- [ ] **`bootstrap.sh` re-run from scratch on a scratch cluster**, since that is now the documented recovery path rather than a one-time setup script

The second box is the one that blocks. **Retiring the seed while backups are local-only trades a recurring annoyance for a single point of failure with no undo.** The current failure loses repositories that are all mirrored on GitHub and reconstructible from a workstation. The post-consolidation failure loses every tenant's database at once.

## Phasing

| Phase | Work | Gated on |
|---|---|---|
| 0 | PVC for seed Gitea | nothing — do this first |
| 1 | Offsite backup for the shared cluster | Mimir Phase 2 |
| 2 | Forgejo deployment consuming its Secret | operator deployed |
| 3 | Push mirrors to GitHub | Forgejo up |
| 4 | Migrate `repoURL`s | 3 |
| 5 | Rehearse `bootstrap.sh` on a scratch cluster | 4 |
| 6 | Retire seed Gitea | the whole gate above |

Phase 0 removes the urgency from everything after it. Phase 1 is the real prerequisite, and the one most likely to be skipped because nothing visibly breaks without it.

## Open questions

1. **Where do Forgejo Actions runners live**, if adopted? The operator image builds on GitHub Actions today, so a GitHub outage stops operator releases — minor now, less so if more builds move in-cluster.
2. **Does the seed's own Postgres HA cluster and Valkey cluster get slimmed first?** Seven pods for a bootstrap host is the pattern Mimir exists to end, but retiring the seed removes them anyway — another argument for keeping Phase 0 cheap.
