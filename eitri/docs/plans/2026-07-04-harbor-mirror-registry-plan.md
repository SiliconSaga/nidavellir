# Harbor Mirror Registry — Implementation Plan (Phases 0–2)

> **Status (2026-07-08): phases 0–2 executed + validated.** The canonical, copy-pasteable runbook is [`../../harbor/README.md`](../../harbor/README.md) plus the checked-in `../../harbor/` artifacts (`values.yaml`, `httproute.yaml`, `setup-proxy-cache.sh`, `containerd/`). The task bodies below are the original plan of record; where an inline snippet predates the shipped artifacts (notably the early nginx-ingress `values.yaml` sketch vs. the shipped Traefik-Gateway exposure), follow the checked-in files, not the snippet.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (this is verification-driven infra ops with human-gated steps, not code TDD). Steps use checkbox (`- [ ]`) syntax. Steps marked **[HUMAN]** are interactive and must be run by the operator (browser auth, DNS, cluster choice); the agent prepares/verifies around them.

**Goal:** Stand up a public-read Harbor pull-through cache on the durable GKE cluster and point a client cluster's containerd at it, so a runtime that can't pull the upstreams directly (e.g. a Docker-Desktop/kind node and `xpkg.crossplane.io`) resolves them through Harbor with no auth.

**Architecture:** Harbor (Helm) on GKE, public-read, exposed at `harbor.cmdbee.org`, with proxy-cache projects for each origin. Docker Desktop node containerd gets a `hosts.toml` mirror pointing the failing `xpkg.*` registries at the Harbor proxy-cache. (Per-cluster Harbor + full 3-tier chain everywhere is a separate follow-up plan — phase 3 of the design.)

**Tech Stack:** Google Cloud SDK + `gke-gcloud-auth-plugin`, GKE, Harbor Helm chart (`https://helm.goharbor.io`), cert-manager + Cloud DNS (already on the GKE cluster), containerd `hosts.toml`.

## Global Constraints

- **Scope = design phases 1–2 only** (GKE Harbor + Docker Desktop unblock). Per-cluster Harbors / k3s + GKE containerd wiring are a follow-up plan.
- **Public-read:** Harbor proxy-cache projects are public (anonymous pull) so auth-less clusters can pull. No push/private projects in scope.
- **Durable target:** Harbor goes on the always-on GKE cluster (the one hosting legacy `terartifactory`), NOT the ephemeral `nordri-test`. Confirm at Task 0.3.
- **Project:** `teralivekubernetes`. **Hostname:** `harbor.cmdbee.org` (tool-named — Harbor only covers OCI; Nexus/Artifactory would get their own subdomains). The `*.cmdbee.org` wildcard DNS (→ Traefik LB) + wildcard cert already cover it, so no per-host DNS or cert action.
- **Do not disturb existing GKE workloads** (the legacy Artifactory + any running stack). Harbor installs into its own `harbor` namespace.
- **Upstreams to proxy:** `xpkg.crossplane.io`, `xpkg.upbound.io`, `quay.io`, `ghcr.io`, `docker.io` (Docker Desktop unblock needs at minimum the two `xpkg.*`).
- **Windows:** winget installs need a shell restart for PATH; interactive `gcloud`/`docker` steps run in the operator's terminal.

---

## Phase 0 — Establish GKE access

### Task 0.1: Install the Google Cloud SDK + GKE auth plugin

**Files:** none (tooling).

- [ ] **Step 1: Install gcloud.** Run: `winget install Google.CloudSDK --accept-source-agreements --accept-package-agreements`
- [ ] **Step 2 [HUMAN]: Restart the shell/IDE** so `gcloud` lands on PATH (winget PATH gotcha).
- [ ] **Step 3: Verify.** Run: `gcloud version` → Expected: prints `Google Cloud SDK <version>`.
- [ ] **Step 4: Install the GKE auth plugin** (kubectl ≥1.26 requires it to auth to GKE). Run: `gcloud components install gke-gcloud-auth-plugin --quiet` then `gke-gcloud-auth-plugin --version` → Expected: version string, no error.

### Task 0.2: Authenticate and select the project

- [ ] **Step 1 [HUMAN]: Log in.** Operator runs (browser opens): `gcloud auth login` — in this session, prefix with `!` so output is captured: `! gcloud auth login`.
- [ ] **Step 2: Set the project.** Run: `gcloud config set project teralivekubernetes` → Expected: `Updated property [core/project].`
- [ ] **Step 3: Verify identity.** Run: `gcloud auth list` → Expected: the operator's account shown as `ACTIVE`.

### Task 0.3: Discover + select the durable cluster, get credentials

- [ ] **Step 1: List clusters.** Run: `gcloud container clusters list --project teralivekubernetes` → Expected: a table of NAME / LOCATION / STATUS. Note each cluster's NAME + LOCATION.
- [ ] **Step 2 [HUMAN]: Confirm the target.** The operator identifies the durable/always-on cluster (the one that should host the public Harbor — likely the one running `terartifactory`, NOT `nordri-test`). Record `GKE_CLUSTER` and `GKE_LOCATION`.
- [ ] **Step 3: Get credentials.** Run: `gcloud container clusters get-credentials <GKE_CLUSTER> --location <GKE_LOCATION> --project teralivekubernetes` → Expected: `kubeconfig entry generated for <GKE_CLUSTER>.` A new context appears in `kubectl config get-contexts` (e.g. `gke_teralivekubernetes_<loc>_<name>`).
- [ ] **Step 4: Verify reach (read-only).** Run: `kubectl --context <gke-context> get nodes` → Expected: GKE nodes `Ready`. Run: `kubectl --context <gke-context> get ns` → confirm the cluster is the expected one (e.g. an existing `argo` / artifactory namespace).
- [ ] **Step 5: Arm the k8s guard on the GKE context** so subsequent Harbor writes can't leak to the wrong cluster. Run: `ws k8s scope set --context <gke-context> --namespace harbor` → then `ws k8s scope show` and echo it. (All Harbor writes below target ns `harbor`; use `ws k8s ...` for them.)

---

## Phase 1 — Harbor on GKE (public-read pull-through cache)

> **Prepared artifacts (the live form — supersedes the nginx-ingress sketch in the tasks below):** exposure is via the shared **Traefik Gateway** (`HTTPRoute` + the existing `*.cmdbee.org` wildcard cert), not nginx. The concrete, reviewed files are under `../../harbor/`: `values.yaml`, `httproute.yaml`, `setup-proxy-cache.sh`, `containerd/*.hosts.toml`, and `README.md` (the deploy runbook). Target cluster confirmed: `ttf-cluster` / `us-east1-d`. GKE default SC `standard-rwo`.

### Task 1.1: Install Harbor via Helm

**Files:**
- Create: `eitri/harbor/values.yaml` (Harbor Helm values — realm-owned GKE infra config)

**Interfaces:**
- Produces: a running Harbor in ns `harbor` on the GKE cluster, reachable at `https://harbor.cmdbee.org`, admin password in a known secret.

- [ ] **Step 1: Add the chart repo.** Run: `helm repo add harbor https://helm.goharbor.io` then `helm repo update` → Expected: `"harbor" has been added`.
- [ ] **Step 2: Write `eitri/harbor/values.yaml`** — expose via ingress on the GKE ingress class, TLS from cert-manager, public external URL, trimmed footprint (no Trivy/Notary for a proxy-cache):

```yaml
expose:
  type: ingress
  tls:
    enabled: true
    certSource: secret          # cert-manager issues into this secret (Task 1.2)
    secret:
      secretName: harbor-tls
  ingress:
    hosts:
      core: harbor.cmdbee.org
    className: <GKE_INGRESS_CLASS>   # confirm from the cluster (Task 1.1 Step 3)
    annotations:
      cert-manager.io/cluster-issuer: <EXISTING_CLUSTERISSUER>   # confirm (Task 1.1 Step 3)
externalURL: https://harbor.cmdbee.org
harborAdminPassword: ""          # set via --set on install (Step 4); never commit a real one
persistence:
  enabled: true
  persistentVolumeClaim:
    registry: { storageClass: standard-rwo, size: 100Gi }   # proxy-cache blob store
    database: { storageClass: standard-rwo, size: 5Gi }
    redis:    { storageClass: standard-rwo, size: 1Gi }
    jobservice:
      jobLog: { storageClass: standard-rwo, size: 1Gi }
trivy:  { enabled: false }
notary: { enabled: false }
metrics: { enabled: false }
```

- [ ] **Step 3: Confirm the two cluster-specific values** the file marks `<...>`: run `kubectl --context <gke> get ingressclass` (pick the default, e.g. `gce` or a Traefik class) and `kubectl --context <gke> get clusterissuer` (pick the letsencrypt prod issuer). Edit `values.yaml` with the real values.
- [ ] **Step 4: Install.** Generate a strong admin password locally (do NOT commit it), then:
  `ws k8s create namespace harbor` ·
  `helm --kube-context <gke> upgrade --install harbor harbor/harbor -n harbor -f eitri/harbor/values.yaml --set-string harborAdminPassword="$HARBOR_ADMIN_PW"`
  → Expected: `STATUS: deployed`.
- [ ] **Step 5: Verify pods.** Run: `kubectl --context <gke> get pods -n harbor` → Expected: `harbor-core`, `-registry`, `-database`, `-redis`, `-jobservice`, `-portal` all `Running`/`Ready` (may take a few minutes + PVC binds).

### Task 1.2: DNS + TLS for `harbor.cmdbee.org`

- [ ] **Step 1: Get the ingress address.** Run: `kubectl --context <gke> get ingress -n harbor` → note ADDRESS (LB IP or hostname).
- [ ] **Step 2 [HUMAN]: Point DNS.** Add an `A`/`CNAME` for `harbor.cmdbee.org` → that address in Cloud DNS zone `cmdbee-org` (mirror how `*.cmdbee.org` is managed; the existing cert-manager DNS-01 setup covers the cert). Verify: `nslookup harbor.cmdbee.org` resolves.
- [ ] **Step 3: Verify the cert.** Run: `kubectl --context <gke> get certificate -n harbor` → Expected: `harbor-tls` `READY=True` (cert-manager issued). Then `curl -fsS https://harbor.cmdbee.org/api/v2.0/health` → Expected: JSON with `"status":"healthy"`.

### Task 1.3: Configure proxy-cache registries + public projects

**Files:**
- Create: `eitri/harbor/setup-proxy-cache.sh` (idempotent Harbor API script)

**Interfaces:**
- Consumes: `harbor.cmdbee.org` reachable (Task 1.2), `HARBOR_ADMIN_PW`.
- Produces: five public proxy-cache projects (`crossplane`, `upbound`, `quay`, `ghcr`, `dockerhub`) each backed by a registry endpoint to its origin.

- [ ] **Step 1: Write `setup-proxy-cache.sh`** — creates each upstream registry endpoint (`POST /api/v2.0/registries`) then a public proxy-cache project bound to it (`POST /api/v2.0/projects` with `registry_id` + `metadata.public:"true"`). Idempotent (treats 409 as ok). Reads `HARBOR_ADMIN_PW` from env; base URL `https://harbor.cmdbee.org`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BASE="https://harbor.cmdbee.org"; U="admin"; P="${HARBOR_ADMIN_PW:?set HARBOR_ADMIN_PW}"
api() { curl -sS -u "$U:$P" -H "Content-Type: application/json" "$@"; }
# name  type            url
mirrors="
crossplane docker-registry https://xpkg.crossplane.io
upbound    docker-registry https://xpkg.upbound.io
quay       docker-registry https://quay.io
ghcr       docker-registry https://ghcr.io
dockerhub  docker-hub      https://hub.docker.com
"
echo "$mirrors" | while read -r name type url; do
  [ -z "$name" ] && continue
  api -X POST "$BASE/api/v2.0/registries" \
    -d "{\"name\":\"$name\",\"type\":\"$type\",\"url\":\"$url\",\"insecure\":false}" \
    -o /dev/null -w "registry $name: %{http_code}\n"    # 201 create / 409 exists = ok
  rid="$(api "$BASE/api/v2.0/registries?q=name%3D$name" | jq -r '.[0].id')"
  api -X POST "$BASE/api/v2.0/projects" \
    -d "{\"project_name\":\"$name\",\"registry_id\":$rid,\"metadata\":{\"public\":\"true\"}}" \
    -o /dev/null -w "project  $name: %{http_code}\n"    # 201 / 409 ok
done
```

- [ ] **Step 2: Run it.** `HARBOR_ADMIN_PW=<pw> bash eitri/harbor/setup-proxy-cache.sh` → Expected: each `registry`/`project` line prints `201` or `409`.
- [ ] **Step 3: Verify a real pull-through** (the load-bearing check): `docker pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4` → Expected: pulls successfully (Harbor fetches from `xpkg.crossplane.io` and caches). Confirm the cache populated: `curl -fsS -u admin:$HARBOR_ADMIN_PW https://harbor.cmdbee.org/api/v2.0/projects/crossplane/repositories` → shows `crossplane/crossplane`.
- [ ] **Step 4: Commit** the Harbor files (values + setup script; NO secrets) to the Eitri component.

---

## Phase 2 — Unblock Docker Desktop via containerd mirror

### Task 2.1: Point Docker Desktop's node containerd at Harbor

**Files:**
- Create: `eitri/harbor/containerd/README.md` (records the mirror mapping + how to apply per node)

**Interfaces:**
- Consumes: the public Harbor proxy-cache projects (Task 1.3).
- Produces: Docker Desktop's kind node containerd resolves `xpkg.crossplane.io` + `xpkg.upbound.io` (+ optionally quay/ghcr/docker.io) via `harbor.cmdbee.org/<project>`.

- [ ] **Step 1: Write the `hosts.toml` mapping** for each failing upstream. For `xpkg.crossplane.io` the file `/etc/containerd/certs.d/xpkg.crossplane.io/hosts.toml`:

```toml
server = "https://xpkg.crossplane.io"
[host."https://harbor.cmdbee.org/v2/crossplane"]
  capabilities = ["pull", "resolve"]
  override_path = true
```

  and the analogous file for `xpkg.upbound.io` → `.../v2/upbound`. (README documents the same pattern for `quay.io`→`quay`, `ghcr.io`→`ghcr`, `docker.io`→`dockerhub` if needed.)
- [ ] **Step 2: Apply into the Docker Desktop node(s).** The kind node is a container named `desktop-worker` (+ `desktop-control-plane`). For each node and each upstream, create the dir + file inside the node, e.g.: `docker exec desktop-worker mkdir -p /etc/containerd/certs.d/xpkg.crossplane.io` then copy the file in (`docker cp <local hosts.toml> desktop-worker:/etc/containerd/certs.d/xpkg.crossplane.io/hosts.toml`). Repeat for `desktop-control-plane` and for `xpkg.upbound.io`.
- [ ] **Step 3: Confirm containerd reads `certs.d`.** Run: `docker exec desktop-worker cat /etc/containerd/config.toml` and verify `config_path = "/etc/containerd/certs.d"` under the CRI registry section. If absent, add it and `docker exec desktop-worker systemctl restart containerd` (or restart the node). Expected: the config_path is set.
- [ ] **Step 4: Verify the node pulls through Harbor.** Delete the stuck pods so kubelet re-pulls: `kubectl delete pod -n crossplane --all`. Watch: `kubectl get pods -n crossplane -w` → Expected: images now pull (no more `xpkg.crossplane.io ... EOF`); pods reach `Running`. (If still failing, check `docker exec desktop-worker crictl pull harbor.cmdbee.org/crossplane/crossplane/crossplane:v2.1.4` directly.)

### Task 2.2: Resume the bootstrap through the mirror

- [ ] **Step 1: Re-run the cluster's bootstrap** (idempotent). Crossplane's images now resolve through Harbor. Expected: the install progresses past the Crossplane layer that previously failed on the upstream pull, then through the remaining layers.
- [ ] **Step 2: Confirm the mirror carried it.** `kubectl get pods -n crossplane` → images pulled, pods `Running` (no `xpkg.crossplane.io … EOF`). The central Harbor's `crossplane` proxy-cache project shows the cached artifact.
- [ ] **Step 3: Record the outcome** (mirror validated, or the next blocker).

---

## Self-Review Notes (spec coverage)

- Public-read Harbor proxy-caching all upstreams → Tasks 1.1–1.3. Fresh/auth-less cluster pulls through the public GKE Harbor → Task 2.1 (Docker Desktop is the concrete case). GKE-first rollout → Phases 1 then 2. containerd mirror config (the substrate wrinkle) → Task 2.1, Docker-Desktop/kind variant only (k3s + GKE variants are the phase-3 follow-up, out of scope here per Global Constraints). Caching-on-pull → verified Task 1.3 Step 3. GKE access prerequisite → Phase 0. Harbor-is-heavy risk → trimmed values (no Trivy/Notary/metrics) in Task 1.1. OCI-artifact pass-through risk → the load-bearing Task 1.3 Step 3 pull of an `xpkg.crossplane.io` artifact. Non-goals (per-cluster Harbor, k3s/GKE containerd wiring, signing/scanning) → intentionally deferred to the phase-3 plan.
