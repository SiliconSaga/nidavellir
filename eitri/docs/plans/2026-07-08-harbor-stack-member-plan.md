# Harbor Stack-Member Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans — this is verification-driven infra ops (Crossplane compositions validated with `crossplane render` + `kubectl`, not code TDD). Steps use checkbox (`- [ ]`) syntax. Steps marked **[HUMAN]** touch a live cluster (install/teardown, migration) and are run by the operator; the agent prepares files and verifies around them.

**Goal:** Turn Harbor from a hand-run `helm install` into an environment-aware Crossplane composition, deployed as a central + local pull-through mesh, with `domain`/`storageClass`/`role` read from cluster-identity and Postgres + valkey vended from Mimir.

**Architecture:** A `Harbor` XRD + composition (`function-environment-configs` loads cluster-identity → `function-go-templating` renders), the openbao/ntfy pattern. The composition emits a Harbor Helm `Release`, an `HTTPRoute`, a Percona `PostgreSQLInstance` claim, a valkey instance, and role-driven proxy-cache projects (origin-targeted for `central`, central-targeted for `local`). GitOps via the nidavellir app-of-apps, ordered after Mimir.

**Tech Stack:** Crossplane (provider-helm, provider-kubernetes, function-environment-configs, function-go-templating), Harbor Helm chart, Mimir Percona-Postgres + valkey operators, ArgoCD, `crossplane render` for offline validation, kuttl for live.

## Global Constraints

- **Follow the openbao composition** verbatim for structure and function wiring: `components/nidavellir/openbao/composition.yaml` (the `load-cluster-identity` `function-environment-configs` step + the `function-go-templating` render step) and `components/nidavellir/openbao/xrd.yaml`. The Harbor composition differs only in the rendered resources.
- **Data-store vending mirrors keycloak:** `components/nidavellir/keycloak/postgres-claim.yaml` (a Percona `PostgreSQLInstance` claim → a `<name>-postgres` ClusterIP Service + `<name>-postgres-user-secret`).
- **Nothing hardcoded in the composition:** `externalURL` and the `HTTPRoute` host are `harbor.{{ $domain }}`; every PVC uses `{{ $identity.storageClass }}`; DB and Redis are `external` (Mimir-vended). No `standard-rwo`, no `harbor.cmdbee.org` literals anywhere in the composition or XRD.
- **Proxy-cache projects are public** (anonymous pull). No push/private projects.
- **Role comes from cluster-identity** (`harborRole` = `central`|`local`; `harborCentral` = the hub hostname, `local` only) — never a claim parameter.
- **Reference charts pin their versions** — capture the exact Harbor chart version in `values`/the Release, do not float `latest`.
- **`*.sh` stays LF** (the `.gitattributes` in nidavellir already pins `*.sh eol=lf`).
- **Spec:** `eitri/docs/plans/2026-07-08-harbor-stack-member-design.md` — every task serves it.

---

## Phase 1 — The composition, `crossplane render`-validated (offline, no cluster)

> Phase 1 produces a composition that renders correctly for both roles against fixture cluster-identities. No live cluster needed; the deliverable is validated entirely with `crossplane render`.

### Task 1: Extend cluster-identity with the Harbor role

**Files:**
- Modify: `components/nordri/platform/fundamentals/manifests/cluster-identity-gke.yaml`
- Modify: `components/nordri/platform/fundamentals/manifests/cluster-identity-homelab.yaml`

**Interfaces:**
- Produces: two new `data` keys on the `cluster-identity` `EnvironmentConfig` — `harborRole` (string `central`|`local`) and, on `local` clusters, `harborCentral` (string, the hub hostname). Consumed by the composition (Task 3+).

- [ ] **Step 1: Add the role to the GKE cluster-identity.** In `cluster-identity-gke.yaml`, under `data:` add:

```yaml
  harborRole: central
```

- [ ] **Step 2: Add the role + hub hostname to the homelab cluster-identity.** In `cluster-identity-homelab.yaml`, under `data:` add:

```yaml
  harborRole: local
  harborCentral: harbor.cmdbee.org
```

- [ ] **Step 3: Validate both are still well-formed EnvironmentConfigs.**

Run: `kubectl apply --dry-run=client -f components/nordri/platform/fundamentals/manifests/cluster-identity-gke.yaml -f components/nordri/platform/fundamentals/manifests/cluster-identity-homelab.yaml`
Expected: `environmentconfig.apiextensions.crossplane.io/cluster-identity configured (dry run)` for each, no schema error.

- [ ] **Step 4: Commit.**

`.commits/harbor-cluster-identity.md` (`add:` the two nordri manifests) → `ws commit nordri` — `feat(cluster-identity): add harborRole/harborCentral`.

### Task 2: The Harbor XRD (claim API)

**Files:**
- Create: `components/nidavellir/eitri/harbor/xrd.yaml`

**Interfaces:**
- Produces: a `CompositeResourceDefinition` for `kind: XHarbor` (group `nidavellir.siliconsaga.org/v1alpha1`, matching the group style of `openbao/xrd.yaml`), with a claim (`HarborInstance`) and minimal `spec.parameters`: `chartVersion` (string, the pinned Harbor chart version) and `registrySize` (string, default `100Gi`, the proxy-cache blob PVC). Role/domain/SC are NOT parameters — they come from cluster-identity. Consumed by Task 3's composition + Task 6's claim.

- [ ] **Step 1: Read the template.** Read `components/nidavellir/openbao/xrd.yaml` — copy its structure (versions, claimNames, connectionSecretKeys pattern).

- [ ] **Step 2: Write `xrd.yaml`.** An `XHarbor`/`HarborInstance` XRD with `spec.parameters` containing exactly `chartVersion` (string, required) and `registrySize` (string, default `"100Gi"`). No `domain`/`storageClass`/`role` params.

- [ ] **Step 3: Validate.**

Run: `kubectl apply --dry-run=client -f components/nidavellir/eitri/harbor/xrd.yaml`
Expected: `compositeresourcedefinition.apiextensions.crossplane.io/... configured (dry run)`, no OpenAPI schema error.

- [ ] **Step 4: Commit.** `ws commit nidavellir` — `feat(eitri): Harbor XRD`.

### Task 3: Composition — `central` role (Release + HTTPRoute from cluster-identity)

**Files:**
- Create: `components/nidavellir/eitri/harbor/composition.yaml`
- Create: `components/nidavellir/eitri/harbor/tests/render/cluster-identity-gke.yaml` (render fixture — a copy of the GKE `EnvironmentConfig` incl. `harborRole: central`)
- Create: `components/nidavellir/eitri/harbor/tests/render/harbor-xr.yaml` (render fixture — a `Harbor` XR with `chartVersion` + `registrySize`)

**Interfaces:**
- Consumes: cluster-identity keys `domain`, `storageClass`, `harborRole` (Task 1); the `Harbor` XR params `chartVersion`, `registrySize` (Task 2).
- Produces: a composition that renders a provider-helm `Release` (Harbor) + a provider-kubernetes `Object` wrapping an `HTTPRoute`. This task covers the `central` path only; DB vending (Task 4) and `local` (Task 5) extend it.

- [ ] **Step 1: Read the template.** Read `components/nidavellir/openbao/composition.yaml` end to end — the `load-cluster-identity` step (`function-environment-configs`, selecting `cluster-identity`), the `function-go-templating` step, and how `$identity.storageClass` / `$domain` are pulled in and stamped into a Helm `Release` + an `HTTPRoute`. Read `components/nidavellir/eitri/harbor/values.yaml` for the exact Harbor values to template.

- [ ] **Step 2: Write the composition skeleton.** Create `composition.yaml` with the same two-step pipeline. In the go-template, bind:

```
{{- $identity := index .context "apiextensions.crossplane.io/environment" -}}
{{- $storageClass := $identity.storageClass -}}
{{- $domain := $identity.domain -}}
{{- $role := $identity.harborRole -}}
{{- $params := .observed.composite.resource.spec.parameters -}}
```

- [ ] **Step 3: Render the Harbor `Release`.** Emit a provider-helm `Release` for the Harbor chart (repo `https://helm.goharbor.io`, `chart: harbor`, `version: {{ $params.chartVersion }}`) whose inline `values` are the current `eitri/harbor/values.yaml` **templated**: `externalURL: https://harbor.{{ $domain }}`, `expose.type: clusterIP` (+ the `clusterIP.name: harbor`, port 80 block), every `persistence.persistentVolumeClaim.*.storageClass: {{ $storageClass }}`, `persistence...registry.size: {{ $params.registrySize }}`, `trivy/notary/metrics` disabled. (DB/redis handled in Task 4 — for now leave the chart defaults so this renders.)

- [ ] **Step 4: Render the `HTTPRoute`.** Emit a provider-kubernetes `Object` wrapping the `HTTPRoute` from `eitri/harbor/httproute.yaml`, with `hostname: harbor.{{ $domain }}` and the same `parentRefs` (kube-system `traefik-gateway`, `websecure`) + `backendRefs` (Service `harbor`:80).

- [ ] **Step 5: Write the render fixtures.** `tests/render/cluster-identity-gke.yaml` = the GKE `EnvironmentConfig` (with `harborRole: central`, `domain: cmdbee.org`, `storageClass: standard-rwo`). `tests/render/harbor-xr.yaml` = a `Harbor` XR with `chartVersion: <pin>` + `registrySize: 100Gi`.

- [ ] **Step 6: Render and verify (central).**

Run: `crossplane render components/nidavellir/eitri/harbor/tests/render/harbor-xr.yaml components/nidavellir/eitri/harbor/composition.yaml components/nidavellir/eitri/harbor/tests/render/functions.yaml -e components/nidavellir/eitri/harbor/tests/render/cluster-identity-gke.yaml`
Expected: output contains a `Release` with `externalURL: https://harbor.cmdbee.org`, all PVC `storageClass: standard-rwo`, and an `HTTPRoute` `hostname: harbor.cmdbee.org`. (Copy `tests/render/functions.yaml` from `openbao`/`ntfy`'s render setup — the function pinnings needed by `crossplane render`.)

- [ ] **Step 7: Commit.** `ws commit nidavellir` — `feat(eitri): Harbor composition — central Release + HTTPRoute from cluster-identity`.

### Task 4: Vended data store (Percona Postgres, external DB) — redis stays chart-bundled

**Files:**
- Modify: `components/nidavellir/eitri/harbor/composition.yaml`

**Interfaces:**
- Consumes: the composition from Task 3.
- Produces: the composition additionally emits a Percona `PostgreSQLInstance` claim (`harbor-postgres`), and the Harbor `Release` values switch to `database.type: external` (pointing at `harbor-postgres:5432`, creds from `harbor-postgres-user-secret`). No bundled Postgres. Redis remains chart-bundled in Phase 1 — valkey-vending (`harbor-valkey` + `redis.type: external`) is **deferred, not implemented here** (see design's Open questions).

- [ ] **Step 1: Read the DB-vending pattern.** Read `components/nidavellir/keycloak/postgres-claim.yaml` (the `PostgreSQLInstance` shape: `apiVersion: database.example.org/v1alpha1`, `parameters.{storageSize,version,replicas,databaseName}`, `compositionSelector` `provider: percona`).

- [ ] **Step 2: Emit the Postgres claim from the composition.** Add a provider-kubernetes `Object` (or a direct MR if the composition can create claims) rendering a `PostgreSQLInstance` named `harbor-postgres` (ns `harbor`), `databaseName: harbor`, `storageSize: 5Gi`, `version: "15"`, `provider: percona` — mirroring `keycloak/postgres-claim.yaml`.

- [ ] **Step 3 (deferred, not implemented in Phase 1): Emit a valkey instance from the composition.** Once valkey-vending lands, add the valkey claim/instance (`harbor-valkey`, ns `harbor`) and switch the Release to `redis.type: external`. Tracked as deferred work in the design doc — Phase 1 leaves redis chart-bundled.

- [ ] **Step 4: Point the Harbor `Release`'s database at Postgres.** In the templated values, set:

```yaml
database:
  type: external
  external:
    host: harbor-postgres
    port: "5432"
    username: <from harbor-postgres-user-secret>   # via existingSecret per Harbor chart
    coreDatabase: harbor
```

Redis stays on the chart's bundled defaults (no `redis.type: external`) until valkey-vending is implemented.

Consult the Harbor chart's `values.yaml` (`helm show values harbor/harbor`) for the exact `database.external.*` keys and the existing-secret mechanism for the DB password.

- [ ] **Step 5: Render and verify.**

Run: the same `crossplane render` command as Task 3 Step 6.
Expected: the output now also contains a `PostgreSQLInstance` `harbor-postgres`, and the `Release` values show `database.type: external` with **no** bundled `database` PVC. Redis/`bitnami` bundled PVCs remain present and unchanged.

- [ ] **Step 6: Commit.** `ws commit nidavellir` — `feat(eitri): vend Harbor Postgres from Mimir (external DB); redis stays chart-bundled`.

### Task 5: The `local` role (central-targeted proxy-cache) + proxy-cache setup

**Files:**
- Modify: `components/nidavellir/eitri/harbor/composition.yaml`
- Create: `components/nidavellir/eitri/harbor/tests/render/cluster-identity-homelab.yaml` (render fixture — homelab `EnvironmentConfig` with `harborRole: local`, `harborCentral: harbor.cmdbee.org`, `domain: homelab.local`, `storageClass: local-path`)

**Interfaces:**
- Consumes: the composition from Task 4; `harborRole`/`harborCentral` from cluster-identity.
- Produces: the composition renders the **proxy-cache project setup** as a post-install `Job` (or a provider-kubernetes `Object` running the existing `setup-proxy-cache.sh` logic), whose upstream targets depend on `$role`: `central` → the five origins; `local` → the single `harborCentral` upstream. Renders correctly for both fixtures.

- [ ] **Step 1: Template the proxy-cache setup by role.** In the composition, render a `Job` (image with `curl`+`jq`, e.g. the Harbor `core` or a small tools image) that runs the `setup-proxy-cache.sh` logic against the in-cluster Harbor. Drive its registry list from `$role`:
  - `central`: the five origin registries (`xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io`) as `docker-registry`/`docker-hub` proxy projects.
  - `local`: a single `docker-registry` proxy project whose URL is `https://{{ $identity.harborCentral }}`.
  Pass `HARBOR_ADMIN_PW` from the Harbor admin secret the chart creates (mount it, don't inline).

- [ ] **Step 2: Write the homelab render fixture** (`tests/render/cluster-identity-homelab.yaml`) as specified in Files.

- [ ] **Step 3: Render and verify BOTH roles.**

Run (central): the Task 3 render command with `-e .../cluster-identity-gke.yaml`.
Expected: the setup Job configures the five origin proxy projects; `externalURL: https://harbor.cmdbee.org`; `storageClass: standard-rwo`.

Run (local): the same command with `-e components/nidavellir/eitri/harbor/tests/render/cluster-identity-homelab.yaml`.
Expected: the setup Job configures ONE proxy project pointed at `https://harbor.cmdbee.org`; `externalURL: https://harbor.homelab.local`; `storageClass: local-path`.

- [ ] **Step 4: Commit.** `ws commit nidavellir` — `feat(eitri): role-driven proxy-cache (central origins vs local→central)`.

---

## Phase 2 — Deploy, migrate, wire clients (live cluster; **[HUMAN]** for install/teardown)

> Phase 2 puts the composition into GitOps, migrates the live central instance onto it, and wires the homelab client. Each task ends with a live verification.

### Task 6: GitOps wiring — Harbor ArgoCD app, ordered after Mimir

**Files:**
- Create: `components/nidavellir/eitri/harbor/claim.yaml` (the `HarborClaim` — `chartVersion`, `registrySize`, ns `harbor`)
- Create: `components/nidavellir/apps/harbor-app.yaml` (ArgoCD Application syncing `eitri/harbor/` — XRD + composition + claim)
- Modify: `components/nidavellir/apps/kustomization.yaml` (add `harbor-app.yaml`)

**Interfaces:**
- Consumes: the composition + XRD (Phase 1); the `PostgreSQLInstance` XRD from Mimir.
- Produces: an ArgoCD `Application` that installs the Harbor XRD/composition/claim, with a sync-wave placing it **after** Mimir (Percona operator + `PostgreSQLInstance` CRD present). One claim; role resolves per-cluster from cluster-identity.

- [ ] **Step 1: Read the ordering pattern.** Read `components/nidavellir/apps/keycloak-app.yaml` (or whichever app depends on Mimir Postgres) for the sync-wave value used to land after Mimir, and `apps/kustomization.yaml` for how apps are registered.

- [ ] **Step 2: Write `claim.yaml`** — a `HarborClaim` (ns `harbor`) with `parameters.chartVersion: <pin>` + `registrySize: 100Gi`.

- [ ] **Step 3: Write `harbor-app.yaml`** — an ArgoCD `Application` (project default, dest `harbor` ns, source path `eitri/harbor`, automated sync + `SkipDryRunOnMissingResource=true`) with the sync-wave from Step 1 (after Mimir).

- [ ] **Step 4: Register it** in `apps/kustomization.yaml`.

- [ ] **Step 5: Validate the kustomization renders.**

Run: `kubectl kustomize components/nidavellir/apps` → Expected: includes the `harbor` Application; no error.

- [ ] **Step 6: Commit.** `ws commit nidavellir` — `feat(eitri): GitOps Harbor app (after Mimir)`.

### Task 7: Migrate the central instance onto the composition **[HUMAN]**

**Interfaces:**
- Consumes: everything above, hydrated to the target cluster's Gitea/ArgoCD.
- Produces: the live central Harbor on the GKE hub is the composition-managed instance (role `central`, cluster-identity domain, Mimir-vended DB), replacing the direct `helm install`.

- [ ] **Step 1 [HUMAN]: Confirm nothing is bootstrapping.** A kind cluster mid-bootstrap would stall while the central is down (design "Reinstall window"). Verify no fresh bootstrap is in flight.
- [ ] **Step 2 [HUMAN]: Tear down the direct install.** `helm --kube-context <hub> uninstall harbor -n harbor`. Leave the `harbor` namespace. (Cached blobs are disposable — they re-warm.)
- [ ] **Step 3: Hydrate + sync.** Re-hydrate nidavellir to the hub's seed-Gitea (`update-embedded-git.sh <target>`), then `kubectl annotate application harbor -n argo argocd.argoproj.io/refresh=hard --overwrite`.
- [ ] **Step 4: Verify the composition brought it up.** `kubectl get harbor,release -n harbor` → the `Harbor` XR + `Release` Ready; `kubectl get pods -n harbor` → core/registry/portal/jobservice/nginx Running; `kubectl get postgresqlinstance -n harbor` → `harbor-postgres` Ready; `kubectl get svc -n harbor` → `harbor-postgres`, valkey, and `harbor` present. **No** in-cluster bundled `harbor-database`/`harbor-redis` StatefulSets.
- [ ] **Step 5: Verify externals + pull-through.** `curl -fsS https://harbor.cmdbee.org/api/v2.0/health` → healthy. `docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4` → succeeds. `kubectl get project`/Harbor API shows the five origin proxy projects.
- [ ] **Step 6: Commit** any fixups discovered during migration.

### Task 8: Homelab k3s client redirect (registries.yaml)

**Files:**
- Create: `components/nidavellir/eitri/harbor/containerd/registries.k3s.yaml` (the `/etc/rancher/k3s/registries.yaml` mirror block: `xpkg.crossplane.io`/`xpkg.upbound.io` → ordered endpoints `local → central → origin`)
- Modify: `components/nidavellir/eitri/harbor/containerd/README.md` (point the k3s section at the checked-in file)

**Interfaces:**
- Consumes: a `local` Harbor on the homelab cluster (Task 6 deploys it there) + the central hub.
- Produces: the k3s registry mirror config that realizes the `local → central → origin` fallback on homelab nodes.

- [ ] **Step 1: Write `registries.k3s.yaml`** with `mirrors.<upstream>.endpoint` ordered `["https://harbor.homelab.local/v2/<project>", "https://harbor.cmdbee.org/v2/<project>", "https://<origin>"]` for both `xpkg.*`. (Confirm the endpoint path-rewrite against the k3s registry docs for the running k3s version, per the README caveat.)
- [ ] **Step 2 [HUMAN]: Apply on a homelab node** — place at `/etc/rancher/k3s/registries.yaml`, `systemctl restart k3s`, then `crictl pull xpkg.crossplane.io/crossplane/crossplane:v2.1.4` → returns a digest.
- [ ] **Step 3: Commit.** `ws commit nidavellir` — `feat(eitri): k3s registries.yaml client redirect`.

### Task 9: Live kuttl test for the composition

**Files:**
- Create: `components/nidavellir/tests/platform/harbor/00-assert.yaml` (assert the `Harbor` XR + `Release` Ready, pods Running, `harbor-postgres`/valkey Services present, the proxy-cache Job succeeded)

**Interfaces:**
- Consumes: the deployed Harbor (Task 7).
- Produces: a kuttl case proving the composition converges + vends its data stores.

- [ ] **Step 1: Read a platform kuttl** (`components/nidavellir/tests/platform/openbao/00-assert.yaml` or `external-secrets/`) for the assert style + how it's registered in `kuttl-test.yaml`.
- [ ] **Step 2: Write `00-assert.yaml`** asserting: `Harbor` XR `Synced`+`Ready`; `Release harbor` Ready; `harbor-core`/`-registry` pods Ready; `PostgreSQLInstance harbor-postgres` Ready; Services `harbor-postgres`, valkey, `harbor` exist. (Match ALL status conditions the live resources carry — the kuttl-conditions gotcha in `components/nordri/CLAUDE.md`.)
- [ ] **Step 3 [HUMAN]: Run it.** `kubectl kuttl test --config components/nidavellir/kuttl-test.yaml` (or `test.ps1` on Windows) → the `harbor` case PASSES.
- [ ] **Step 4: Commit.** `ws commit nidavellir` — `test(eitri): kuttl for Harbor composition`.

---

## Self-Review Notes (spec coverage)

- **Composition + cluster-identity (domain/SC/role):** Tasks 1, 3 (render-proven). **Nothing hardcoded:** Task 3 (domain/SC) + Task 4 (external DB/redis) — asserted in render. **Mimir-vended Postgres+valkey:** Task 4. **Central vs local roles + role-driven proxy-cache:** Task 5 (both fixtures rendered). **GitOps after Mimir:** Task 6. **Reinstall-not-adopt migration:** Task 7 (with the design's reinstall-window guard as Step 1). **Per-substrate client redirect:** kind already shipped (`wire-containerd-kind.sh`), homelab k3s = Task 8, GKE = no node redirect (nothing to build; manifest-level pinning is optional and deferred). **Testing (render + kuttl):** render in Tasks 3–5, kuttl in Task 9.
- **Deferred (design non-goals / open questions):** manifest-level image pinning on GKE (optional, not built); own-registry/signing/scanning (out of scope); the Harbor-chart-accepts-valkey and central-URL-discovery open questions are flagged in Task 4 Step 4 / the design and validated live at Task 7.
