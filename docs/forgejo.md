# Forgejo — the durable-tier git platform

The runbook for `forgejo/`. The design of record is the realm's [Forgejo day-2 design](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/docs/plans/2026-09-07-forgejo-day2-design.md); Phase 2 (this composition, its Jobs and the puller) is in the [Phase 2 design](https://github.com/SiliconSaga/realm-siliconsaga/blob/main/docs/plans/2026-09-19-forgejo-day2-phase2-design.md) and its plan. In one breath: GitHub owns `main` and review; Forgejo is a writable in-cluster host whose `main` an in-cluster **puller** writes from GitHub; ArgoCD will read Forgejo (Phase 3). No GitHub credential exists anywhere.

## What ships, and when

`apps/forgejo-app.yaml` (sync-wave 11) builds `forgejo/` with kustomize: the `forgejo` Namespace, the `XForgejo` XRD (claim kind `ForgejoInstance`), the composition, and the `forgejo-scripts` ConfigMap (the four scripts under `forgejo/scripts/`). All of it merges and hydrates everywhere.

The **claim** is realm content (`realm-siliconsaga/cluster/forgejo/claim.yaml`, delivered by the realm root-app): org, maintained repositories with their GitHub upstreams, vendor mirrors, break-glass admins. nidavellir never learns those names.

The composition reads `maturity` from cluster-identity:

| maturity | renders |
|---|---|
| `bootstrap` (every fresh cluster) | nothing — the XR is Ready with zero composed resources |
| `durable`, `full` | everything below |
| anything else | the render fails, naming the field |

Graduating a cluster is an identity edit (`maturity: durable` on its cluster-identity manifest), hydrated in. `bootstrap.sh` never produces one.

## What renders at durable, in order

Ordering is by observed readiness, not sync-waves. Watch it with `kubectl get dataservice,externalsecret,job,release,cronjob -n forgejo -w`.

1. **DataService `forgejo`** (`engine: postgres`, `placement: shared`) → Secret `forgejo-dataservice` (`host`, `port`, `database`, `username`, `password`, `uri`).
2. **RBAC and inputs**: ServiceAccounts `forgejo-init` (the Jobs; may `create` Secrets and `get`/`update` the one named `forgejo-puller`) and `forgejo-puller` (no token mounted, no RBAC); ConfigMap `forgejo-repos` (`repos` and `mirrors`, one `<name> <upstream>` per line, rendered from the claim).
3. **ExternalSecrets** `forgejo-admin` (from `secret/forgejo`, keys `username`/`password`) and `forgejo-admin-<user>` per break-glass admin (from `secret/forgejo/admins/<user>`). Until the credentials Job has written those paths they report `SecretSyncedError` — that is the gate, not a failure.
4. **Credentials Job** `forgejo-credentials-<hash>`: logs in to OpenBao with Kubernetes auth as role `forgejo-init` (nordri's `openbao_configure` creates it), and for each path writes a generated password **create-only** (`cas: 0`) if `secret/metadata/<path>` answers 404. A sealed OpenBao fails the Job loudly.
5. **Helm Release** `forgejo` (chart `oci://code.forgejo.org/forgejo-helm/forgejo`, the claim's exact version), once the admin Secret and the DataService are Ready: `fullnameOverride: forgejo` (Service `forgejo-http:3000`, PVC `forgejo-data`), `strategy: Recreate`, admin from `forgejo-admin`, database over the shared pgBouncer with `SSL_MODE: require`, user and password through `FORGEJO__DATABASE__*` env from the DataService Secret, SSH off, registration off, metrics on.
6. **HTTPRoute** `forgejo.<domain>` on the shared Gateway's `websecure` listener.
7. **Configure Job** `forgejo-configure-<hash>`, once the Release is Ready: org; repositories created **empty**; the puller token (below); break-glass accounts with the passwords ESO delivered, admin flag set; `main` branch protection (pushes only for the admin and the break-glass accounts — the accounts must exist first, Forgejo rejects a rule naming an unknown user); vendor mirrors as Forgejo pull-mirrors. Every step is check-then-act; existing maintained repositories are never modified.
8. **Puller CronJob** `forgejo-puller`, once the configure Job succeeded. Schedule: cluster-identity `pullerSchedule`, else the claim's, else hourly.

The XR is Ready only when every composed resource is; a failed Job holds it not-Ready, which surfaces as the `forgejo` Application Degraded. Read the Job's pod log.

## Credentials

- `secret/forgejo` — the admin (`forgejo-admin` by default). Consumed by the chart (`gitea.admin.existingSecret`, `passwordMode: keepUpdated`) and by the configure Job. Nothing on a workstation reads it.
- `secret/forgejo/admins/<user>` — each break-glass admin. Read one with `kubectl get secret -n forgejo forgejo-admin-<user> -o jsonpath='{.data.password}' | base64 -d`, or from OpenBao (nordri `lib/openbao.sh`, `openbao_run_with_token 'bao kv get secret/forgejo/admins/<user>'`).
- Secret `forgejo-puller` (key `token`) — the only credential the puller holds: a Forgejo access token named `puller` on the admin account, scope `write:repository`, minted by the configure Job. Never in OpenBao; Forgejo's token list is the audit surface.

### The puller token's three states

| Secret `forgejo-puller` | token authenticates | Forgejo has a token named `puller` | the Job |
|---|---|---|---|
| present | yes | yes | keeps it |
| absent | — | no | mints one and creates the Secret |
| anything else | | | stops with `PullerTokenInvalid` (exit 3) |

"Authenticates" is checked against `GET /repos/search`, a repository-scoped endpoint: a `write:repository` token has no `read:user` scope, so `GET /user` would call a good token invalid. A token's value cannot be read back from Forgejo, so the Job never mints a replacement on its own — that would leave untracked tokens behind. Only `ROTATE=puller` does: revoke by name, mint, rewrite the Secret.

### Rotating the puller token

Run the configure script as a one-off Job with `ROTATE=puller`:

```bash
kubectl get job -n forgejo -o name | grep forgejo-configure-          # the current one
kubectl get job -n forgejo forgejo-configure-<hash> -o yaml \
  | yq 'del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.labels, .metadata.ownerReferences, .spec.selector, .spec.template.metadata.labels)
        | .metadata.name = "forgejo-rotate-puller"
        | (.spec.template.spec.containers[0].env[] | select(.name == "ROTATE")).value = "puller"' \
  | kubectl create -f -
kubectl logs -n forgejo job/forgejo-rotate-puller -f
kubectl delete job -n forgejo forgejo-rotate-puller
```

### Rotating admin passwords (manual for now)

`bao kv put secret/forgejo password=<new> username=forgejo-admin` (a new version; the Job never overwrites), wait for ESO (`refreshInterval: 1h`, or `kubectl annotate externalsecret -n forgejo forgejo-admin force-sync=$(date +%s)`), and the chart's `keepUpdated` re-applies the admin's password on the next pod start. A break-glass password needs the same `bao kv put` plus a `PATCH /api/v1/admin/users/<user>` by hand; `ROTATE=admins` (which would also revoke that account's tokens) is a follow-up.

## Re-running a Job

Jobs are immutable and named by a hash of their inputs (org, admin, break-glass list, repos, mirrors) plus a `jobGeneration` constant in the composition. A claim change makes a new Job; a **script change must bump `jobGeneration`** or the old Job keeps its name and never re-runs. To re-run the current one by hand, delete it: provider-kubernetes recreates it. Old Jobs from earlier generations linger; delete them by hand.

## The puller

For each line of `forgejo-repos`: fresh `git init`, fetch Forgejo `main` (its tip becomes the lease), fetch GitHub `main`, push `refs/remotes/github/main:refs/heads/main` with `--force-with-lease=refs/heads/main:<tip>` (an empty tip when the branch does not exist yet: "must not exist"). Only `main` is written. One failing repository does not stop the others; the run exits non-zero if any failed, which `KubeJobFailed` reports.

- On demand: `kubectl create job -n forgejo --from=cronjob/forgejo-puller puller-manual-$(date +%s)`.
- Suspend: `kubectl patch cronjob -n forgejo forgejo-puller -p '{"spec":{"suspend":true}}'` — the switch Phase 3's hydration flow flips. Visible in `kubectl get cronjob`.

**Forgejo 15 has no force-push allowlist**: a protected branch rejects non-fast-forward pushes from everyone (`CreateBranchProtectionOption` carries `enable_push`, `enable_push_whitelist`, `push_whitelist_usernames` and nothing for force pushes). That is why repositories are created empty rather than `auto_init` (the first push creates `main`), and why the puller's ordinary runs are fast-forwards. A genuine divergence — Phase 3's hydration pushing an orphan snapshot to Forgejo `main` — will be rejected by protection and show up as a failed puller run; Phase 3's resume flow has to handle it (drop and recreate the rule around the pull, or push a fast-forwardable state).

## Vendor mirrors

Forgejo pull-mirrors (`POST /repos/migrate`, `service: git`, `mirror: true`), tags included, default interval. The API cannot change a pull mirror's upstream after creation, so a mirror whose `original_url` differs from the claim is **deleted and re-migrated** — a mirror is derived data. If `original_url` is empty for a `service: git` migration on this version, drift is not detectable and the Job says so.

## Teardown

Lowering cluster-identity `maturity` below `durable` while Forgejo resources exist is **refused**: the XR reports the render failure (`kubectl describe xforgejo`) and nothing is touched. To tear down on purpose, set `allowTeardown: true` on the claim in the same hydration. Everything goes except the PVC `forgejo-data` (the chart's `helm.sh/resource-policy: keep`) and what the app ships (Namespace, ConfigMap); the DataService deletion drops the database. Delete the PVC by hand. Never on GKE.

## Troubleshooting

- **ExternalSecrets `SecretSyncedError`, no Release**: the credentials Job has not succeeded. `kubectl logs -n forgejo job/forgejo-credentials-<hash>`. `OpenBao is SEALED` is exactly that; a login failure means the `forgejo-init` role is missing on the vault — `nordri/openbao-configure.sh <target> <realm>`.
- **Release never Ready**: `kubectl describe release` and the `forgejo` pod's log; the usual cause is the database (`forgejo-dataservice` Secret, pgBouncer reachability, `SSL_MODE`).
- **Configure Job exit 3**: `PullerTokenInvalid`, above.
- **Application Degraded, XR not Ready**: one composed resource is not Ready; `kubectl get xforgejo -o yaml` lists which.
- **`argocd_app_info` missing**: unrelated to Forgejo — nordri's `argocd` Application turns on the controller metrics Heimdall scrapes.
