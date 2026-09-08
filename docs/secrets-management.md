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

### Security limitations (read these before reusing the pattern anywhere serious)

Spelled out so nobody has to infer severity from the narrative above:

- **Anyone who can read Secrets in the `openbao` namespace owns the whole substrate.** The parked `root_token` grants unrestricted OpenBao operations (read everything, rewrite policies, reconfigure auth). The parked shares unseal directly only while the effective seal is `shamir`; after graduation they are recovery keys, and the daily unseal path is Cloud KMS IAM on gke or the `openbao-seal-key` Secret on homelab — which on homelab is the same namespace, so the exposure is unchanged there. Either way it defeats the multi-party control that Shamir splitting exists to provide. The live-env password-manager copy mitigates *key loss*, not this *exposure*.
- **Secret values cross the cluster network in plaintext.** The listener runs `tls_disable = 1` and ESO reads over `http://openbao.openbao.svc:8200`, so anything with in-cluster network visibility (pod exec in the `openbao`/`external-secrets` namespaces, CNI-level capture, a future service-mesh sidecar) can observe values during ESO refresh cycles.

Both are accepted for the staging substrate and synthetic data only. Treat them as **blocking** for anything holding real credentials or member data until the remaining hardening lands. Custody: KMS auto-unseal is now in place on gke (ADR 0004), so the parked shares there are recovery keys rather than the daily unseal path, but the parked root token is still all-powerful and homelab still holds its seal key in-cluster. Transit: a cert-manager/vegvisir-issued listener cert plus HTTPS/`caBundle` on the store is still outstanding.

## How to use it (the 90% case)

**Put a value in** (any path under `secret/`):

```bash
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao kv put secret/myapp api-key=swordfish
```

Using the root token here is a staging-posture convenience. Best practice reserves the root token for bootstrap and recovery; if you're doing routine value management (or copying this pattern toward production), mint a scoped operator token instead — `bao policy write kv-write` with write capabilities over `secret/data/*`, then `bao token create -policy=kv-write -ttl=8h` — and use that as `BAO_TOKEN`.

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
kubectl exec -n openbao openbao-0 -- bao operator raft snapshot inspect /tmp/pre-migrate.snap   # must list the KV mount and report a sane size
kubectl cp openbao/openbao-0:/tmp/pre-migrate.snap ./openbao-pre-migrate-$(date +%Y%m%d).snap
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

Run once per OpenBao instance. On a **live env**, have the password manager open — shares go there first.

```bash
kubectl exec -n openbao openbao-0 -- bao operator init -key-shares=3 -key-threshold=2 -format=json
# → save unseal_keys_b64 + root_token (password manager FIRST on live envs)
# unseal with 2 shares (commands above), then park the material in-cluster:
kubectl create secret generic openbao-init -n openbao --from-file=init.json=<saved-json> --from-literal=root_token=<token>
```

Then the one-time mount/auth/policy setup (KV v2 at `secret/`, Kubernetes auth, `eso-read` policy + `eso-role`): the exact command sequence lives in the OpenBao/ESO setup plan, realm-siliconsaga `docs/plans/2026-06-09-leidangr-phase1a-openbao-eso-plan.md`, Task A1.5 Step 3. Seed `secret/demo` with `foo=bar` so the kuttl smoke and the demo ExternalSecret go green.

Windows/Git Bash note: prefix `kubectl exec`/`kubectl cp` commands that carry absolute in-container paths with `MSYS_NO_PATHCONV=1`, or MSYS rewrites them to Windows paths (see realm dev-setup → MSYS Path Mangling).

### Lost the unseal shares

Staging: accept the loss — delete the openbao PVC and Helm release pod state, let the composition reconcile, re-init. Live: this is the disaster the password-manager copy exists to prevent; if both copies are truly gone the data is cryptographically unrecoverable (that's the design), so rebuild and re-populate.

## Verifying and testing

- **kuttl smokes** (`tests/platform/openbao/`, `tests/platform/external-secrets/`): StatefulSet readiness (proves the unseal flow ran) and a full write-KV → ExternalSecret → materialized-Secret round trip in an ephemeral namespace. Run via `./test.ps1` (Windows/Docker) — see [Testing](testing.md).
- **Offline composition check** (`tests/render/`): `crossplane render` validates the composition's env-aware seams without a cluster. Fixtures + usage line in `tests/render/openbao-xr.yaml`; CLI install in realm dev-setup. Use it before any composition change ships.
- **Live spot-check:** `kubectl get clustersecretstore openbao-kv` should report Ready; `kubectl get secret demo-from-openbao -n external-secrets` is the always-on canary (materialized from `secret/demo`).

## What's deliberately NOT here yet

- **HA** — still a single replica. Auto-unseal landed (ADR 0004); a second replica is its own change.
- **TLS inside the cluster** — an active risk, not just a missing feature; see "Security limitations" above for the exposure scope. The hardening phase fronts the listener with a cert (cert-manager/vegvisir) and flips the ClusterSecretStore to HTTPS + `caBundle`.
- **Dynamic secrets / rotation** — KV v2 static values only for now. Keycloak consumes static values via ESO first; dynamic DB credentials are a later conversation.
- **App-side OpenBao SDKs / agent injector** — intentionally avoided (ADR 0003). Consume through ExternalSecrets; if you think you need direct API access from a workload, raise it as a design question first.
