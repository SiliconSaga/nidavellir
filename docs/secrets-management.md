# Secrets Management — OpenBao + External Secrets Operator

How the platform stores and delivers secrets: what OpenBao is, what "sealed" means (the part that confuses everyone at first), how External Secrets Operator (ESO) turns OpenBao values into ordinary Kubernetes Secrets, and the runbooks for the situations you'll actually hit — a restarted pod, a fresh cluster, a value to add.

Decision records: realm-siliconsaga `docs/adrs/0001`–`0003`. Implementation: this repo's `openbao/` directory + `apps/external-secrets-app.yaml` (PR #13). For a full worked example of the chain end to end — an OpenBao-born secret flowing through ESO into a live consumer — see `demos/sso/`.

## The mental model in one diagram

```text
 you (operator)                        a workload that needs a secret
      │                                          │
      │ bao kv put secret/myapp token=...        │ mounts/env-refs a plain
      ▼                                          │ Kubernetes Secret
 ┌──────────────┐   Vault-compatible API   ┌─────┴──────────────┐
 │   OpenBao    │ ◄──────────────────────  │  ExternalSecret CR │
 │ (ns openbao) │   read-only, k8s auth    │  (any namespace)   │
 └──────────────┘                          └────────────────────┘
   the truth                                 ESO copies the value into a
   encrypted at rest                         Secret object and keeps it fresh
```

Two halves, two jobs:

- **OpenBao** is the system of record. Values live there, encrypted, versioned, behind policies. Nothing consumes OpenBao directly.
- **ESO** is the delivery mechanism. You declare an `ExternalSecret` ("materialize key X from store Y into Secret Z") and ESO does the copying and refreshing. Workloads never know OpenBao exists — they see a normal Kubernetes Secret.

Why not just use Kubernetes Secrets directly? You still do — at the consumption end. OpenBao adds what bare Secrets lack: one place to put a value that several namespaces/clusters need, versioning, audit, revocable policies, and (later) dynamic credentials. The pattern scales from "one shared API token" to "Keycloak's DB password rotates hourly" without changing how workloads consume anything.

## Inventory: what actually holds a credential

The deeper platform credentials, and how each is held. Kept here because "is this value in OpenBao or hand-applied?" was repeatedly being answered by grepping, and because the *gaps* are the interesting rows. Verified against the live GKE cluster 2026-09-15.

| What | Where the truth lives | How it reaches the workload | Keyless? |
| --- | --- | --- | --- |
| Shared MySQL off-site backup (GCS HMAC) | OpenBao `secret/mimir-mysql-backup` | ESO → `mimir-mysql-backup-s3` in `mimir` | ❌ **cannot be** — see below |
| OpenBao Raft snapshot upload (GCS HMAC on gke, Garage key on homelab) | `openbao-backup-s3` Secret (ns `openbao`), parked by nordri (`gke-provision.sh openbao-backup-setup` / bootstrap Layer 5) — not in OpenBao, since the job that uses it is the one that backs OpenBao up | the chart's `openbao-snapshot` CronJob, `s3CredentialsSecret` | ❌ **cannot be** — s3cmd speaks only S3, same reason as MySQL |
| Harbor | OpenBao `secret/harbor` | ESO → `nidavellir/eitri/harbor/externalsecret.yaml` | n/a (static by nature) |
| Leidangr OIDC | OpenBao `secret/leidangr/…` | ESO → `keycloak/leidangr-oidc-realm-secrets` | n/a |
| ESO → OpenBao auth | nothing stored | Kubernetes auth, SA token exchange | ✅ |
| Shared Postgres off-site backup | nothing stored | Workload Identity, `repo2-gcs-key-type: auto` | ✅ |
| Velero → GCS | nothing stored | Workload Identity, `credentials.useSecret: false` | ✅ |
| OpenBao recovery keys + root token | `openbao-init` Secret (ns `openbao`) + the shared password safe (written by `nordri/openbao-init.sh`) | the parked root token, by the configure/seed scripts; recovery keys only for `generate-root` and seal migration under `seal: auto` | ❌ by design (ADR 0002 → 0004) |
| Gitea admin | `gitea-admin-credentials` Secret (ns `gitea`) | read by the hydration script | ❌ not in OpenBao |
| **XenForo DB password** | plain Secret, hand-applied | `xenforo-secrets` | ❌ **not in OpenBao** |
| Grafana admin | see `heimdall/docs/grafana-admin-credentials.md` | chart-managed Secret | ❌ not in OpenBao |

Two rows worth acting on: XenForo already *has* an `ExternalSecret` written (`xenforo-k8s/kustomize/components/secrets-openbao/externalsecret.yaml`) but the live cluster is still running the plain-Secret flavor — it has not been cut over. Gitea's admin credential is the bootstrap dependency that OpenBao itself sits behind, so it is genuinely awkward to move rather than merely unmoved.

## GCP storage integrations are keyless — with one that cannot be

Scope this claim carefully, because the inventory's non-keyless rows are not all the same kind of thing. Harbor and the Leidangr OIDC values are static *by nature* — there is no identity to federate, they are just secrets. Gitea's admin credential is a bootstrap dependency. Neither is a keyless failure.

Two distinct keyless mechanisms are in play here, and conflating them makes the count wrong:

- **ESO → OpenBao** is keyless via **Kubernetes auth** — `mountPath: kubernetes`, `role: eso-role`, and a ServiceAccount reference in `openbao/secretstore.yaml`. No GCP, no Workload Identity, nothing stored. It is the delivery path, not a cloud integration.
- **GCP storage integrations** are keyless via **Workload Identity**. Exactly **two** rows: Postgres `repo2` (`repo2-gcs-key-type: auto`) and Velero → GCS (`credentials.useSecret: false`).

It is that second group that sets the expectation. So when a *GCP storage* integration turns up holding a static credential, the question is always "why wasn't this keyless?" — and there is exactly one case where the honest answer is *it cannot be keyless*:

**The Percona PXC operator has no native GCS backend.** It supports exactly `filesystem`, `s3`, `azure`. The Percona *Postgres* operator supports `gcs:` with `gcs-key-type: auto`, which is why `repo2` next door is keyless. MySQL therefore reaches GCS through its **S3-interoperability endpoint** (`https://storage.googleapis.com`), and that API authenticates with **HMAC keys** — which Workload Identity cannot issue. Swapping the `credentialsSecret` for an `iam.gke.io/gcp-service-account` annotation does not work; `xbcloud` 403s.

The mitigation is blast radius, not elimination:

- a dedicated GSA (`mysql-backup@…`) holding `roles/storage.objectAdmin` on **one bucket only** — not project-wide, not on the Velero or pgBackRest buckets
- the key lives in OpenBao, materialized by ESO, never in Git
- a recovery copy in the workspace `.env`, because of the seal posture below

**Custody of that recovery copy**, since a second copy of a live credential deserves stating rather than implying. It lives in the *yggdrasil workspace* `.env` — not in this repo or any component repo — which is:

- **untracked and ignored.** `.env` is line 2 of the workspace `.gitignore`, and `git ls-files` confirms it has never been tracked. Component repos do not ignore `.env`, which is fine because the file is not in them; do not "fix" that by scattering the credential into repo-local `.env` files.
- **local-only and permission-restricted — `chmod 600`.** It was `0644` when the MySQL key was first appended, meaning any local account could read it. Check it after anything appends to it; a `>>` does not change an existing file's mode.

It is deliberately *not* in the operator's password manager. That guidance covers the OpenBao shares and root token, which gate the whole substrate. This key gates one bucket and is reconstructible by minting a new HMAC key for the same GSA, so the cheap local copy is proportionate.

Reach for this shape only when the consuming operator genuinely has no keyless path. Check the operator's supported storage types before assuming it needs a key.

## Sealing, explained from zero

This is the concept that trips up everyone new to Vault-family tools, so here it is from first principles.

OpenBao encrypts everything it stores with a **master key** that exists only in memory, never on disk. When the process starts, it does not have that key — the encrypted data sits there unreadable, like a bank vault door swung shut. That state is called **sealed**. A sealed OpenBao is running and answering its API port, but it can decrypt nothing and will refuse almost every operation.

**Unsealing** is handing the master key back. The master key was split (Shamir's Secret Sharing) into N **unseal key shares** when the server was first initialized — ours uses 3 shares with a threshold of 2, meaning any 2 of the 3 shares reconstruct the master key. You unseal by submitting shares one at a time until the threshold is met. The split exists so that no single person/credential holds the whole key, and losing one share isn't fatal.

The lifecycle, and when each step happens:

| Step | Happens | What it does |
|---|---|---|
| **init** | ONCE per OpenBao instance, ever | Generates the master key, splits it into the 3 shares, creates the **root token** (the initial all-powerful login). If you re-init, the old data is gone — init is creation, not login. |
| **unseal** | Depends on the claim's **effective seal mode**. With `parameters.seal: auto` and the one-time migration done (ADR 0004), it is automatic after every process start: gke unwraps the barrier key through Cloud KMS via Workload Identity, homelab through a static key in Secret `openbao-seal-key`. With `seal` omitted or `shamir` — the XRD default, and every cluster's state until an operator graduates it — it is the manual two-share unseal of ADR 0002 after every restart. | Until unsealed the pod runs but stays **NotReady** — readiness gates on seal status. On an `auto` cluster a pod that stays NotReady after a restart signals broken seal prerequisites; on a `shamir` cluster it signals a human is needed, as before. |
| **login/use** | Continuously | Normal API operations with tokens (the root token, or scoped tokens like ESO's k8s-auth-issued one). |

Practical consequences worth internalizing:

- **A restarted OpenBao pod unseals itself — once the claim says `seal: auto` and the migration has run.** If it stays `0/1` after a restart on such a cluster, the seal backend is unreachable: on gke check the KSA annotation and the KMS IAM (`./gke-provision.sh openbao-seal-setup` repairs both), on homelab check that Secret `openbao-seal-key` exists. `bao status` says `Sealed true` with `Seal Type gcpckms`/`static` in that case. A `Seal Type shamir` means the cluster has not been graduated (or the migration below never ran) and wants the manual unseal.
- **Sealed ≠ stopped.** The API answers (`bao status` works) but reads/writes fail. ESO's store will show not-ready, ExternalSecrets stop refreshing — already-materialized Kubernetes Secrets keep working, since they're copies.
- **The root token is a login credential, not the encryption key.** Losing unseal shares = data unrecoverable. Losing the root token while unsealed = recoverable (you can generate a new root with the shares).
- The Shamir shares from init did not disappear: after migration they are **recovery keys**, needed for `bao operator generate-root` and for `-migrate`-ing back to Shamir. Keep them where they were.

## What's deployed (the substrate shape)

OpenBao ships as a Crossplane composition (`openbao/composition.yaml`), same pattern as ntfy/heimdall: `function-environment-configs` loads `cluster-identity`, `function-go-templating` renders a Helm `Release` plus an `HTTPRoute`. Env-awareness comes from cluster-identity: homelab gets `local-path` storage and `openbao.homelab.local`; GKE gets `standard-rwo` and `openbao.cmdbee.org`.

Shape choices that matter when you're debugging:

- **Single replica, Raft storage, standalone mode.** One pod: `openbao-0`. No HA — this is a staging-grade substrate, hardened later.
- **`fullnameOverride: openbao`** pins the StatefulSet/Service/pod names to plain `openbao` / `openbao-0`. Without it the Helm release inherits the claim's random XR suffix and every stable reference (the store URL below, runbook commands, kuttl asserts) would chase a moving name.
- **ESO is a plain Helm ArgoCD app** (`apps/external-secrets-app.yaml`, sync-wave 9 — one before openbao's 10 so the CRDs exist first). It's env-agnostic, so no composition is warranted.
- **The bridge** is `openbao/secretstore.yaml`: a cluster-scoped `ClusterSecretStore` named `openbao-kv` pointing at `http://openbao.openbao.svc:8200`, authenticating via **Kubernetes auth** — ESO's ServiceAccount token is exchanged for an OpenBao token bound to the read-only `eso-read` policy. No static credential anywhere in that path.
- KV v2 secrets engine is mounted at `secret/`. A demo value `secret/demo` (`foo=bar`) exists as the smoke-test fixture.

## Custody posture: test vs live

This substrate started on the **minimal unseal posture** (ADR 0002) and now auto-unseals (ADR 0004); the custody of the init material is unchanged by that. The init output — unseal shares (now recovery keys) and root token — is parked in-cluster in the `openbao-init` Secret (ns `openbao`), with the root token duplicated as its own `root_token` key so tests can read it without JSON parsing. Anyone with cluster admin can read that Secret. That is an accepted tradeoff, not an oversight:

- **homelab (staging, resettable):** in-cluster custody only. If everything is lost, wipe and re-init — nothing of value is at stake.
- **GKE (live):** the same Secret exists for operational convenience, but the unseal shares and root token ALSO go into the operator's password manager at init time, BEFORE the in-cluster copy is created. If the cluster eats the Secret, you can still unseal.
- **Auto-unseal (ADR 0004, landed with the Forgejo day-2 Phase 1):** gke holds the barrier key in Cloud KMS, reached through Workload Identity; homelab holds a static key in Secret `openbao-seal-key`. The parked `openbao-init` material remains the recovery keys and root token. The homelab posture is honest about being homelab: anyone who can read Secrets in `openbao` can unseal, exactly as before, but nobody has to.

> **⚠ LIVE STATE, GKE, verified 2026-09-15: auto-unseal is available but NOT YET IN EFFECT here.**
>
> Auto-unseal landing in Git and a given cluster actually using it are two different facts, and only the first is visible from this repo. The XRD defaults `seal` to `shamir` precisely so merging ADR 0004 is inert, so every cluster stays manual until an operator runs the graduation below. `bao status` on ttf-cluster still reports:
>
> ```
> Seal Type    shamir
> Total Shares 3
> Threshold    2
> Active Since 2026-09-07T00:45:05Z
> ```
>
> `Seal Type: shamir` is the whole answer — a graduated cluster reports `gcpckms` with `Recovery Seal Type shamir`. So this cluster still needs two shares after any restart.
>
> The reason that has not hurt yet is the `Active Since` line: the pod has not restarted in over a week, so nobody has been asked. It reads as automatic without being automatic, which is why "I thought we did the special thing on GKE" is such an easy belief to hold. Check rather than trust either recollection or this paragraph:
>
> ```bash
> kubectl exec -n openbao openbao-0 -- bao status
> ```
>
> **What a seal does and does not break.** A sealed OpenBao cannot serve reads, so no `ExternalSecret` can *refresh*. But already-materialized Secrets persist — ESO does not delete a target on refresh failure, and `deletionPolicy: Retain` makes that explicit — so running workloads keep working while sealed. What breaks is needing to **create or recreate** a Secret during a seal. That is the scenario the `.env` recovery copy of the MySQL HMAC key exists for: it lets a backup target be rebuilt without first finding two shares.

### Security limitations (read these before reusing the pattern anywhere serious)

Spelled out so nobody has to infer severity from the narrative above:

- **Anyone who can read Secrets in the `openbao` namespace owns the whole substrate.** The parked `root_token` grants unrestricted OpenBao operations (read everything, rewrite policies, reconfigure auth). The parked shares unseal directly only while the effective seal is `shamir`; after graduation they are recovery keys, and the daily unseal path is Cloud KMS IAM on gke or the `openbao-seal-key` Secret on homelab — which on homelab is the same namespace, so the exposure is unchanged there. Either way it defeats the multi-party control that Shamir splitting exists to provide. The live-env password-manager copy mitigates *key loss*, not this *exposure*.
- **Secret values cross the cluster network in plaintext.** The listener runs `tls_disable = 1` and ESO reads over `http://openbao.openbao.svc:8200`, so anything with in-cluster network visibility (pod exec in the `openbao`/`external-secrets` namespaces, CNI-level capture, a future service-mesh sidecar) can observe values during ESO refresh cycles.

Both are accepted for the staging substrate and synthetic data only. Treat them as **blocking** for anything holding real credentials or member data until the remaining hardening lands. Custody: KMS auto-unseal is now in place on gke (ADR 0004), so the parked shares there are recovery keys rather than the daily unseal path, but the parked root token is still all-powerful and homelab still holds its seal key in-cluster. Transit: a cert-manager/vegvisir-issued listener cert plus HTTPS/`caBundle` on the store is still outstanding.

## How to use it (the 90% case)

**Put a value in** (any path under `secret/`). This is the shortest form, shown for orientation — it puts both the token and the value in the container's process arguments, so use the stdin form below for anything that is not a throwaway:

```bash
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao kv put secret/myapp api-key=swordfish
```

Using the root token here is a staging-posture convenience. Best practice reserves the root token for bootstrap and recovery; if you're doing routine value management (or copying this pattern toward production), mint a scoped operator token instead — `bao policy write kv-write` with write capabilities over `secret/data/*`, then `bao token create -policy=kv-write -ttl=8h` — and use that as `BAO_TOKEN`.

**Prefer stdin for anything real.** The `api-key=swordfish` form above is fine for the demo value, but a `key=value` argument lands in the container's process arguments, where anything able to read `/proc` on that node sees it.

**And the token is argv too.** `env BAO_TOKEN="$ROOT_TOKEN" bao …` exposes the *root token* exactly the same way — worse, since it gates everything rather than one value. Moving only the payload to stdin and leaving the token in `env` fixes the smaller half of the problem. Send both over stdin: first line the token, the rest the JSON payload.

```bash
{ printf '%s\n' "$ROOT_TOKEN"; cat payload.json; } \
  | kubectl exec -i -n openbao openbao-0 -- \
      sh -c 'read -r T; BAO_TOKEN="$T" exec bao kv put secret/mimir-mysql-backup -'
```

`read -r T` consumes the first line; `BAO_TOKEN="$T"` is a shell assignment *inside* the container, so it reaches the process environment without ever appearing in any command line. Keeping the payload in a file rather than a literal also keeps it out of shell history. Under the `ws k8s` guard, `-i` must come *after* the pod name (`ws k8s exec -n openbao openbao-0 -i -- …`) — the guard rejects unrecognised options positioned before the resource.

**Verify by round-trip, with a check that actually fails — on EVERY field.** Printing the stored JSON proves only that the read succeeded; a successful read of a *truncated* value looks identical. And checking one field is barely better: an HMAC pair whose access-key ID matches while the secret is truncated passes a single-field check and then fails at the point of use. Compare the whole payload:

```bash
printf '%s\n' "$ROOT_TOKEN" \
  | kubectl exec -i -n openbao openbao-0 -- \
      sh -c 'read -r T; BAO_TOKEN="$T" bao kv get -format=json secret/mimir-mysql-backup' \
  | python3 -c '
import json, sys
stored = json.load(sys.stdin)["data"]["data"]
expected = json.load(open("payload.json"))
bad = sorted(k for k in expected if stored.get(k) != expected[k])
extra = sorted(set(stored) - set(expected))
if bad or extra:
    sys.exit("MISMATCH — differing: %s; unexpected: %s" % (bad or "none", extra or "none"))
print("all %d fields match" % len(expected))
'
```

Exits non-zero and **names the offending field** without printing any value, and catches an extra key left behind by an earlier write. Both the read and the comparison are piped, so neither the token nor the payload reaches an argv on either side.

Verified against a throwaway path in both directions, including the specific case worth caring about: ID correct, secret truncated by three characters — reported `differing: ['AWS_SECRET_ACCESS_KEY']` and exited 1. A mangled credential looks completely normal in a terminal and fails much later, with an authentication error that implicates the wrong component entirely.

**Inventory what is there** — useful before adding a value, and the source of the table at the top of this doc (paths and key names only, never values):

```bash
printf '%s\n' "$ROOT_TOKEN" \
  | kubectl exec -i -n openbao openbao-0 -- \
      sh -c 'read -r T; BAO_TOKEN="$T" bao kv list secret/'
```

**Consume it from any namespace** — declare an ExternalSecret; ESO materializes and refreshes a plain Secret next to your workload:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: myapp-credentials
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-kv          # the cluster-scoped store — works from any namespace
    kind: ClusterSecretStore
  target:
    name: myapp-credentials   # the Kubernetes Secret ESO creates/maintains
  data:
    - secretKey: api-key      # key inside the materialized Secret
      remoteRef:
        key: secret/myapp     # OpenBao path
        property: api-key     # field within that path
```

**Check it worked:**

```bash
kubectl get externalsecret myapp-credentials -n myapp        # SecretSynced / Ready
kubectl get secret myapp-credentials -n myapp -o jsonpath='{.data.api-key}' | base64 -d
```

### The KV v2 path gotcha (read this before writing policies)

KV v2 inserts `data/` into the **API** path but not the **CLI or ESO** path. You write `bao kv put secret/myapp` and reference `key: secret/myapp` in an ExternalSecret — but a policy granting access must say `path "secret/data/myapp"`. Our `eso-read` policy is `path "secret/data/*"` for exactly this reason. If you ever write a policy with `path "secret/*"` semantics in mind and wonder why reads fail or why you needed `data/`, this is why. (Metadata operations — listing, version history — live under `secret/metadata/...`, a separate grant.)

## Runbooks

### The pod restarted and shows 0/1

Expected to resolve itself within a minute. If it does not:

```bash
kubectl exec -n openbao openbao-0 -- bao status      # Seal Type + Sealed
kubectl logs -n openbao openbao-0 --tail=50          # "failed to unseal" names the backend error
```

Only a cluster still on `Seal Type shamir` needs the old two-share unseal; run the migration below instead of unsealing by hand again.

ESO recovers on its own within each ExternalSecret's `refreshInterval` once the pod is Ready; to hurry one along, annotate that ExternalSecret (`kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`), then remove the annotation, since it drifts from Git. The annotation is read on ExternalSecrets, not on the ClusterSecretStore.

### Migrating an initialized OpenBao to auto-unseal (one-time, HUMAN-GATED)

Prerequisites: on gke, `./gke-provision.sh openbao-seal-setup` has run; on homelab, bootstrap Layer 2.9 created `openbao-seal-key` (on an older homelab cluster, run `kubectl create secret generic openbao-seal-key -n openbao --from-literal=key="$(openssl rand -base64 32)"` once). And on either: **a verified Raft snapshot from before the migration.** OpenBao must be unsealed to take one, so if the pod is currently sealed, unseal it the old way first (two shares, `bao operator unseal`).

```bash
kubectl exec -n openbao openbao-0 -- bao operator raft snapshot save /tmp/pre-migrate.snap
kubectl exec -n openbao openbao-0 -- ls -l /tmp/pre-migrate.snap   # OpenBao 2.5 has only `save` and `restore` — no `inspect`; a sane size is the check
kubectl cp openbao/openbao-0:/tmp/pre-migrate.snap ./openbao-pre-migrate-$(date +%Y%m%d).snap   # gke: `ws k8s cp` under the armed scope instead
```

Then compare the copy's size to the in-pod size, and stop if they differ:

```bash
snapshot="./openbao-pre-migrate-$(date +%Y%m%d).snap"
pod_bytes="$(kubectl exec -n openbao openbao-0 -- wc -c /tmp/pre-migrate.snap | awk '{print $1}')"
local_bytes="$(wc -c < "$snapshot")"
printf 'in-pod: %s bytes; local: %s bytes\n' "$pod_bytes" "$local_bytes"
[ "$pod_bytes" -gt 0 ] && [ "$pod_bytes" -eq "$local_bytes" ] || { echo "snapshot copy incomplete — do not continue" >&2; false; }
```

Keep the copy off-cluster until step 5 has passed; `bao operator raft snapshot restore` is the way back if the migration goes wrong. (Windows/Git Bash: `MSYS_NO_PATHCONV=1` in front of the `kubectl exec`/`cp` lines.)

1. Set `parameters.seal: auto` on the claim (`openbao/claim.yaml`), commit, and hydrate (`update-embedded-git.sh <env> realm-siliconsaga`). The XRD default is `shamir`, so nothing changed when the XRD landed; this commit is the graduation. **Wait for the `openbao` XR to render successfully before going on** — `kubectl get xopenbao openbao -o jsonpath='{.status.conditions}'` shows `Synced=True` with no render error — since the XR reports a transient failure if it reconciles before `layer4-fundamentals` has delivered the new cluster-identity fields. Give it up to five minutes; if it still fails, the fields did not arrive (check `kubectl get environmentconfig cluster-identity -o yaml` for `gcpProject`/`gcpRegion` on gke) and nothing below should run.
2. **Restart the pod yourself.** The chart's StatefulSet uses `updateStrategy: OnDelete` and carries no config checksum, so on both environments the running pod keeps its old Shamir config until something deletes it: `kubectl delete pod openbao-0 -n openbao`. Wait for the replacement container to be **Running** (`kubectl get pod openbao-0 -n openbao -w`); it will not become Ready, because a Shamir-initialized barrier does not know the new seal yet, and `bao status` shows `Seal Type gcpckms` (or `static`) with `Sealed true`. This is the only restart that still needs a human. Do not skip this step: a pod left running looks healthy while the migration is merely armed, and the next unplanned restart lands sealed at an unplanned hour.
3. Migrate with two shares (password manager on live envs, else `openbao-init`). Run interactively so each share is typed at the prompt rather than passed on the command line, where it would land in shell history and `ps` output:

```bash
kubectl exec -it -n openbao openbao-0 -- bao operator unseal -migrate
kubectl exec -it -n openbao openbao-0 -- bao operator unseal -migrate
```

4. Verify: `bao status` now reports `Seal Type gcpckms` (or `static`) and `Recovery Seal Type shamir`, `Sealed false`.
5. Prove it: `kubectl delete pod openbao-0 -n openbao` once more, then watch it return `1/1` unaided. This is also `tests/platform/openbao/01-restart.yaml`.

Rolling back: set `parameters.seal: shamir` on the claim, hydrate, delete the pod (same OnDelete reason), then `bao operator unseal -migrate` with the same shares reverses the migration. If the barrier itself is damaged, `bao operator raft snapshot restore` from the pre-migration snapshot is the way back.

### Fresh cluster (or wiped PVC) — full init

Run once per OpenBao instance, from the nordri checkout, with the kubectl context on the right cluster (the scripts refuse a mismatch). On homelab, `bootstrap.sh` does all of this itself (Layer 5b); on gke it is deliberately a human step so the material reaches the password safe:

```bash
./openbao-init.sh gke ~/openbao-init/gke.json      # init once; parks Secret openbao/openbao-init AND writes the JSON to that file (0600, in a 0700 directory it creates)
# → move the file's contents (recovery keys + root token) into the shared password safe, then: rm -r ~/openbao-init
./openbao-configure.sh gke realm-siliconsaga       # KV v2, Kubernetes auth, eso-read/eso-role, openbao-backup, secret/demo, realm seeds
```

Under `seal: auto` the instance unseals itself and the three shares in the init output are **recovery** keys; under Shamir the script unseals from the parked shares. `openbao-init.sh` refuses an initialized instance — init material exists exactly once — and never prints it. Custody is realm ADR 0002's in-cluster Secret plus the safe: two copies in two failure domains (the reasoning is in the realm's go-live design, `docs/plans/2026-09-16-openbao-go-live-design.md`).

Windows/Git Bash note: prefix `kubectl exec`/`kubectl cp` commands that carry absolute in-container paths with `MSYS_NO_PATHCONV=1`, or MSYS rewrites them to Windows paths (see realm dev-setup → MSYS Path Mangling).

### Backups — daily Raft snapshots

Two layers, the shape every stateful service here follows:

- **Engine-level**: the OpenBao Helm chart's snapshot agent, enabled by the composition. CronJob `openbao/openbao-snapshot` logs in through Kubernetes auth as ServiceAccount `openbao-snapshot` with role `openbao-backup` (read on `sys/storage/raft/snapshot`, nothing else — the job can copy the vault out encrypted and read no secret), runs `bao operator raft snapshot save` and uploads with s3cmd at 05:00 UTC. Retention is 30 days either way, but by different hands: on gke the bucket's lifecycle rule expires objects and the agent's identity can only create and read (no delete, no overwrite — a compromised backup pod cannot erase history); on homelab the agent deletes expired objects itself, since Garage has no lifecycle rule provisioned. One bucket per environment: `gs://<project>-openbao-backups/openbao/` on gke over the GCS S3-interop endpoint with an HMAC key (`./gke-provision.sh openbao-backup-setup` mints it into Secret `openbao/openbao-backup-s3`; keyless is impossible because s3cmd speaks only S3, the same reasoning as Mimir's MySQL backups), Garage bucket `openbao-backups` on homelab (bootstrap Layer 5 creates key, bucket and the same Secret).
- **Disk-level**: Velero's 06:00 UTC schedule snapshots the `openbao` PVC on gke, crash-consistent. It is the net under the engine backup, not a substitute: the Raft snapshot is the vault's own export and restores into any instance whose seal can open it.

The snapshot is ciphertext sealed by the barrier; the bucket holds nothing readable without the KMS key (gke) or the static key (homelab). Heimdall alerts `OpenBaoSnapshotStale` (no success in 36h) and `OpenBaoSnapshotNeverSucceeded` (CronJob present, never succeeded, 26h), and `HeimdallDatabaseBackupFailed` covers a failed upload Job; the Backups dashboard has a "time since last OpenBao Raft snapshot" tile.

Prove it rather than assume it — after the first configure, and after any change to the bucket, key or role:

```bash
kubectl create job --from=cronjob/openbao-snapshot -n openbao openbao-snapshot-manual
kubectl -n openbao wait --for=condition=complete job/openbao-snapshot-manual --timeout=5m
kubectl -n openbao logs job/openbao-snapshot-manual                     # "upload: ... -> s3://..." from s3cmd
gcloud storage ls gs://<project>-openbao-backups/openbao/                 # gke
MSYS_NO_PATHCONV=1 kubectl exec -n garage garage-0 -c garage -- /garage bucket info openbao-backups   # homelab: Objects > 0
kubectl -n openbao delete job openbao-snapshot-manual
```

The two usual first-run failures: `permission denied` on login means the `openbao-backup` role is missing (run `openbao-configure.sh`); an s3cmd 403 means the Secret's key does not match the bucket's grant (re-run the provisioning step).

### Restoring

Two procedures. The first was exercised on the local homelab on 2026-09-17: a fresh init under the static seal, one manual `openbao-snapshot` run to Garage (20.9 KB), a marker written afterwards, then a restore of that object from a one-off pod running the agent image (it carries both s3cmd and `bao`, with `BAO_TOKEN` from the `openbao-init` Secret) — the canary and the seeded OIDC path came back, the marker was gone, the instance stayed unsealed and ESO's store stayed valid. One detail worth knowing: a Job created with `kubectl create job --from=cronjob/...` does count toward the CronJob's last-success time, so a manual run also satisfies the tile and the alerts.

**From a Raft snapshot** (the vault's own export — the normal path). Target: an initialized, unsealed instance whose seal can open the snapshot: the same KMS key on gke, the same `openbao-seal-key` on homelab.

```bash
gcloud storage cp gs://<project>-openbao-backups/openbao/bao_<date>.snapshot ./restore.snapshot        # gke
# homelab: any S3 client against garage.garage.svc.cluster.local:3900 with the openbao-backup-key credentials, or `kubectl port-forward -n garage svc/garage 3900`
MSYS_NO_PATHCONV=1 kubectl cp ./restore.snapshot openbao/openbao-0:/tmp/restore.snapshot
MSYS_NO_PATHCONV=1 kubectl exec -i -n openbao openbao-0 -- sh -c 'BAO_TOKEN="$(cat /dev/stdin)" bao operator raft snapshot restore /tmp/restore.snapshot' < <(kubectl get secret -n openbao openbao-init -o jsonpath='{.data.root_token}' | base64 --decode)
kubectl exec -n openbao openbao-0 -- rm /tmp/restore.snapshot
```

The restore replaces the whole Raft state, including the auth mounts and the parked-token's validity: after it, the root token that is valid is the one from the instance the snapshot was taken on. When restoring into the *same* instance (the common case: a bad write, a lost mount) nothing changes. When restoring into a **re-initialized** instance — same seal, fresh init — the order matters: authenticate with the *new* instance's root token (the one in its current `openbao-init` Secret, which is what the command above reads) and run `bao operator raft snapshot restore -force`, since the consistency check would otherwise reject a snapshot from a different cluster identity. Only *after* the restore succeeds does the snapshot's root token become the valid one, so then replace the parked `openbao-init` Secret with the material the snapshot was taken under (from the safe), and keep the new instance's init material in the safe as well until the restore is confirmed. ESO's `ClusterSecretStore` recovers by itself since its Kubernetes-auth role travels inside the snapshot. The seal must be the *same*: the snapshot's barrier is wrapped by the seal it was taken under, and `-force` only skips the consistency check, it does not make a different KMS key or static key able to open it — recovery keys cannot either. If the seal has changed (a rebuilt KMS key, a new static key), restore into an instance configured with the original seal material first, then run the seal migration; if the original seal material is gone, the snapshot is unreadable.

**From Velero** (disk-level, gke). A Velero restore of the `openbao` namespace brings back the PVC and the `openbao-init` Secret together; under `seal: auto` the pod unseals itself as long as the KMS key still exists. Crash-consistent: a snapshot taken mid-write can need the Raft snapshot path above instead.

And the sentence that matters most: **the KMS key (gke) or `openbao-seal-key` Secret (homelab) is what opens every copy of the vault.** The KMS key cannot be deleted outright (destruction is scheduled, 24-hour minimum) and its key ring can never be deleted, which is why the setup uses one dedicated key with one narrow grant. Losing the homelab static key Secret with no copy elsewhere means every homelab snapshot is unreadable — acceptable for a resettable cluster, and the reason no homelab holds anything that is not regenerable.

### Lost the recovery keys (or, on Shamir, the unseal shares)

Two different losses, and only one of them loses data:

- **Recovery keys, under `seal: auto`** (the `openbao-init` Secret, the safe copy and Velero's copy of the Secret all gone): the barrier is still opened by the KMS key or `openbao-seal-key`, so the vault keeps unsealing and nothing is lost. What is blocked is every recovery-key-authorized operation — `generate-root` (the only way to mint a new root token if the parked one is also gone) and a seal migration. Do not rebuild for this; the next scheduled hardening step, a scoped operator token, is what reduces the blast radius of losing the root token.
- **The seal material** (the KMS key destroyed, or the homelab `openbao-seal-key` Secret gone with no copy): every copy of the vault, including every Raft snapshot, is unreadable. Live: this is the disaster the KMS key's scheduled-destruction window exists to prevent. Staging: accept the loss — delete the openbao PVC, let the composition reconcile, re-init and re-seed.
- **Shamir unseal shares** (an instance not yet graduated): below the threshold, the instance cannot be unsealed after its next restart; the data is intact on disk but locked. Same answer as the seal material: recover the shares from the safe, or rebuild.

## Verifying and testing

- **kuttl smokes** (`tests/platform/openbao/`, `tests/platform/external-secrets/`): StatefulSet readiness (proves the unseal flow ran) and a full write-KV → ExternalSecret → materialized-Secret round trip in an ephemeral namespace. Run via `./test.ps1` (Windows/Docker) — see [Testing](testing.md).
- **Offline composition check** (`tests/render/`): `crossplane render` validates the composition's env-aware seams without a cluster. Fixtures + usage line in `tests/render/openbao-xr.yaml`; CLI install in realm dev-setup. Use it before any composition change ships.
- **Live spot-check:** `kubectl get clustersecretstore openbao-kv` should report Ready; `kubectl get secret demo-from-openbao -n external-secrets` is the always-on canary (materialized from `secret/demo`).

## What's deliberately NOT here yet

- **HA** — still a single replica. Auto-unseal landed (ADR 0004); a second replica is its own change. Note `bao status` already reports `HA Enabled: true` with Raft storage against that one replica, so the line is HA *plumbing*, not HA — do not read it as redundancy.
- **TLS inside the cluster** — an active risk, not just a missing feature; see "Security limitations" above for the exposure scope. The hardening phase fronts the listener with a cert (cert-manager/vegvisir) and flips the ClusterSecretStore to HTTPS + `caBundle`.
- **Dynamic secrets / rotation** — KV v2 static values only for now. Keycloak consumes static values via ESO first; dynamic DB credentials are a later conversation.
- **App-side OpenBao SDKs / agent injector** — intentionally avoided (ADR 0003). Consume through ExternalSecrets; if you think you need direct API access from a workload, raise it as a design question first.
