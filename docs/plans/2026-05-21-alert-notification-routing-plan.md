# Alert Notification Routing (ntfy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Heimdall's already-firing self-health alerts to the operator's phone via a self-hosted ntfy server, reachable over Tailscale, with severity-tiered priority and a documented-but-dormant webhook seam for Knarr's future SMS/call escalation.

**Architecture:** ntfy runs as a standalone in-Nidavellir Crossplane composition (mirroring `cluster-identity-demo`), env-aware via `cluster-identity` EnvironmentConfig — active (`replicas: 1`) on GKE, cold standby (`replicas: 0`) on homelab. GKE's ntfy joins the tailnet via the Tailscale Kubernetes operator and is exposed by a Service annotation; the phone and the homelab AlertManager reach it over the tailnet, nothing public. The heimdall composition's kube-prometheus-stack `alertmanager.config` gains a severity-routing tree pointing at ntfy.

**Tech Stack:** Crossplane (function-go-templating, function-environment-configs, provider-kubernetes, provider-helm), kube-prometheus-stack / Prometheus AlertManager, ntfy, Tailscale Kubernetes operator, ArgoCD, kuttl (infra tests).

**Design:** [docs/plans/2026-05-21-alert-notification-routing-design.md](2026-05-21-alert-notification-routing-design.md)

**Conventions for this repo (read before starting):**
- Commits go through `ws commit <component> <bodyfile>` (never raw git). Each "Commit" step below means: write a `.commits/<name>.md` bodyfile with `message:` + `add:` frontmatter, then `bash scripts/ws commit <component> <bodyfile>`.
- Work on a topic branch per component; `main` is protected. Push with `ws push <component>`.
- "Tests" here are kuttl cases and `kubectl` assertions, not unit tests — this is GitOps/infra.
- Components touched: `nidavellir` (ntfy composition + app wiring + Tailscale operator app), `heimdall` (AlertManager routing). Validate on the local `rancher-desktop` (homelab) cluster; GKE-only behavior is validated by reading rendered manifests since the homelab path sets `replicas: 0`.
- This doc lives in the `nidavellir` repo, but file paths below are **workspace-root-relative** (e.g. `components/nidavellir/ntfy/xrd.yaml`), because agents work from the yggdrasil workspace root via `ws exec`. Inside the nidavellir repo itself those map to `ntfy/xrd.yaml`, etc.

---

## File Structure

**New (in `components/nidavellir/`):**
- `ntfy/xrd.yaml` — XRD `XNtfy` (parameters: `replicas` override, `tailscaleHostname`, `topic`).
- `ntfy/composition.yaml` — pipeline: load cluster-identity → render ntfy ConfigMap/Secret/PVC/Deployment/Service via provider-kubernetes Objects, env-aware.
- `ntfy/claim.yaml` — the `Ntfy` claim.
- `ntfy/README.md` — what it is, how to test, the Tailscale dependency.
- `apps/ntfy-app.yaml` — ArgoCD Application (mirror `heimdall-app.yaml`), `path: ntfy`, sync-wave after Vegvísir.
- `apps/tailscale-operator-app.yaml` — ArgoCD Application deploying the Tailscale operator (Provider-Helm Release or Helm-type App).
- `tailscale/` — operator config (values, namespace), if not fully inline in the app.

**Modified:**
- `apps/kustomization.yaml` — register `ntfy-app.yaml` and `tailscale-operator-app.yaml`.
- `components/heimdall/crossplane/composition.yaml:120` — add `alertmanager.config` routing tree + receivers.

**Secrets (created out-of-band, not committed):**
- `tailscale/operator-oauth` (clientId/clientSecret) in the operator namespace.
- `ntfy/ntfy-auth` (admin token / access tokens) in the `ntfy` namespace.
- `heimdall/ntfy-webhook` (ntfy publish URL/token; later the Knarr webhook URL) in the `heimdall` namespace.

---

## Task Group A — Tailscale foundation (spike → concrete)

> This group is spike-shaped by agreement: Tailscale has no precedent in this repo. Pin the mechanism against current Tailscale docs, verify connectivity, *then* commit manifests. Do not write the ntfy tasks' Tailscale annotations until Task A2 confirms the expose mechanism.

### Task A1: Pin the Tailscale-on-GKE mechanism + create tailnet credentials

**Files:** none yet (research + tailnet-side setup + a short decision note appended to `components/nidavellir/ntfy/README.md` later).

- [ ] **Step 1: Confirm the operator is the right vehicle.** In the Tailscale admin console, confirm the **Tailscale Kubernetes operator** is current (Helm chart `tailscale/tailscale-operator`). Note the chart version. Expected: operator is the documented way to expose a cluster Service to a tailnet.
- [ ] **Step 2: Create an OAuth client** in the Tailscale admin console (Settings → OAuth clients) with scopes `devices:write` (and `auth_keys` if required by the operator version), tagged `tag:k8s-operator`. Record clientId/clientSecret in the workspace secret store (NOT in git).
- [ ] **Step 3: Define ACL tags.** In the tailnet ACL, ensure `tag:k8s-operator` and `tag:ntfy` exist and that the phone's user/device is allowed to reach `tag:ntfy:80`. Document the exact ACL stanza in `ntfy/README.md` (created in Task B4).
- [ ] **Step 4: Decide homelab egress.** Determine how a homelab (`rancher-desktop`) pod reaches a tailnet MagicDNS name. Two candidates: (a) the workstation host is already on the tailnet and k3s can route via the host; (b) a Tailscale subnet-router/operator on homelab too. Run the spike in Task A3 before committing to one. Record the decision in `ntfy/README.md`.

### Task A2: Deploy + verify the Tailscale operator on GKE

**Files:**
- Create: `components/nidavellir/apps/tailscale-operator-app.yaml`
- Modify: `components/nidavellir/apps/kustomization.yaml`

- [ ] **Step 1: Pre-create the operator OAuth Secret** on the target cluster (manual, out-of-band):

```bash
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id="<clientId>" \
  --from-literal=client_secret="<clientSecret>"
```

Expected: `secret/operator-oauth created`.

- [ ] **Step 2: Write the ArgoCD Application for the operator.** Create `components/nidavellir/apps/tailscale-operator-app.yaml`, a Helm-source Application (mirror the structure of `heimdall-app.yaml` but with a Helm `source`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tailscale-operator
  namespace: argo
  annotations:
    argocd.argoproj.io/sync-wave: "4"   # before ntfy (wave 6); after core platform
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://pkgs.tailscale.com/helmcharts
    chart: tailscale-operator
    targetRevision: "<pinned-version-from-A1>"
    helm:
      values: |
        oauthSecretVolume:
          secret:
            secretName: operator-oauth
        apiServerProxyConfig:
          mode: "false"
  destination:
    server: https://kubernetes.default.svc
    namespace: tailscale
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 3: Register the app.** Add `- tailscale-operator-app.yaml` to `components/nidavellir/apps/kustomization.yaml` resources list (above `ntfy-app.yaml`).
- [ ] **Step 4: Sync + verify operator health.**

```bash
kubectl annotate application nidavellir -n argo argocd.argoproj.io/refresh=hard --overwrite
kubectl rollout status deploy/operator -n tailscale --timeout=180s
```

Expected: operator deployment Available; a device named per the operator appears in the Tailscale admin console.

- [ ] **Step 5: Commit** (`.commits/nidavellir-tailscale-operator.md`, `ws commit nidavellir`).

### Task A3: Verify homelab→tailnet egress (decides ntfy cross-cluster reach)

**Files:** none (spike; outcome documented in `ntfy/README.md`).

- [ ] **Step 1: Stand up a throwaway tailnet device** (e.g., expose a temporary `nginx` Service on GKE via `tailscale.com/expose`, or use any existing tailnet MagicDNS name).
- [ ] **Step 2: From a homelab pod, attempt to reach it:**

```bash
kubectl run nettest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sS -m 5 http://<magicdns-name>/
```

Expected: either it connects (homelab routes to the tailnet via the host → no homelab operator needed) or it times out (homelab needs its own subnet-router/operator).

- [ ] **Step 3: Record the outcome** in `ntfy/README.md`. If homelab needs an operator, add a follow-up note — for v1 the homelab AlertManager can still point at the *in-cluster* standby ntfy Service (only used when the standby is scaled up), so cross-cluster homelab→GKE delivery is a nice-to-have, not a v1 blocker. Confirm this fallback in the AlertManager task (C).

---

## Task Group B — ntfy server (Nidavellir composition)

### Task B1: Scaffold the XRD

**Files:**
- Create: `components/nidavellir/ntfy/xrd.yaml`

- [ ] **Step 1: Write the XRD.** Mirror `cluster-identity-demo/xrd.yaml` shape:

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xntfys.nidavellir.siliconsaga.org
spec:
  group: nidavellir.siliconsaga.org
  names:
    kind: XNtfy
    plural: xntfys
  claimNames:
    kind: Ntfy
    plural: ntfys
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                parameters:
                  type: object
                  properties:
                    replicasOverride:
                      type: integer
                      description: "Optional override for replica count. When unset, the composition sets 1 on gke (active) and 0 on homelab (cold standby)."
                    tailscaleHostname:
                      type: string
                      default: "ntfy"
                      description: "Tailnet device hostname for the ntfy Service (MagicDNS). gke only."
                    baseUrl:
                      type: string
                      description: "ntfy base-url (e.g. http://ntfy.<tailnet>.ts.net). Set per environment."
```

- [ ] **Step 2: Validate YAML parses.** Run: `kubectl apply --dry-run=client -f components/nidavellir/ntfy/xrd.yaml`. Expected: `created (dry run)` with no schema errors.
- [ ] **Step 3: Commit** (`.commits/nidavellir-ntfy-xrd.md`).

### Task B2: Write the composition (cluster-identity load + ntfy objects)

**Files:**
- Create: `components/nidavellir/ntfy/composition.yaml`

- [ ] **Step 1: Write the composition.** Pipeline mirrors `cluster-identity-demo/composition.yaml`: Step 0 loads `cluster-identity`; Step 1 renders ntfy objects via provider-kubernetes. Key env-aware logic: `replicas` = `replicasOverride` if set, else `1` when `$env == "gke"` else `0`. Render these `kubernetes.crossplane.io/v1alpha2` Objects into namespace `ntfy`:

  - **ConfigMap `ntfy-server-config`** — `server.yml` with `base-url`, `auth-file: /var/lib/ntfy/user.db`, `auth-default-access: "deny-all"`, `cache-file`, `behind-proxy: true`.
  - **PVC `ntfy-data`** (`storageClassName: {{ $identity.storageClass }}`, 1Gi) — holds auth + message cache.
  - **Deployment `ntfy`** — image `binwiederhier/ntfy:<pinned>`, `args: ["serve"]`, mounts the ConfigMap at `/etc/ntfy/server.yml` and the PVC at `/var/lib/ntfy`, `replicas` per the env logic above.
  - **Service `ntfy`** — port 80→80; on gke add annotations `tailscale.com/expose: "true"` and `tailscale.com/hostname: {{ .observed.composite.resource.spec.parameters.tailscaleHostname }}` (gated `{{- if eq $env "gke" }}`), confirmed available by Task A2.

Use the `function-environment-configs` Step 0 block verbatim from `cluster-identity-demo/composition.yaml` (lines 17-27) and the `function-go-templating` Object-rendering shape from its Step 1. Pin the ntfy image tag in Step 2 below before finalizing.

- [ ] **Step 2: Pin the ntfy image tag.** Run: `crane ls binwiederhier/ntfy` (or check Docker Hub) and set a specific tag (e.g. `v2.x.y`), not `latest`. Record it in the Deployment manifest.
- [ ] **Step 3: Validate parse.** Run: `kubectl apply --dry-run=client -f components/nidavellir/ntfy/composition.yaml`. Expected: dry-run OK.
- [ ] **Step 4: Commit** (`.commits/nidavellir-ntfy-composition.md`).

### Task B3: Write the claim

**Files:**
- Create: `components/nidavellir/ntfy/claim.yaml`

- [ ] **Step 1: Write the claim:**

```yaml
apiVersion: nidavellir.siliconsaga.org/v1alpha1
kind: Ntfy
metadata:
  name: ntfy
  namespace: ntfy
spec:
  parameters:
    tailscaleHostname: ntfy
    # baseUrl set after Task A2 confirms the MagicDNS name, e.g.:
    # baseUrl: "http://ntfy.<your-tailnet>.ts.net"
```

- [ ] **Step 2: Validate parse.** Run: `kubectl apply --dry-run=client -f components/nidavellir/ntfy/claim.yaml`. Expected: dry-run OK (CRD must exist; if not, dry-run client still parses YAML structure).
- [ ] **Step 3: Commit** (`.commits/nidavellir-ntfy-claim.md`).

### Task B4: Pre-create the ntfy auth Secret + README

**Files:**
- Create: `components/nidavellir/ntfy/README.md`

- [ ] **Step 1: Document** in `ntfy/README.md`: purpose, the Tailscale dependency + ACL stanza (from A1), the homelab-egress decision (from A3), how to create the auth token, and how to test (Task E). No secrets in the file.
- [ ] **Step 2: After first deploy, create the ntfy admin user + access token** (out-of-band; documented in README):

```bash
kubectl exec -n ntfy deploy/ntfy -- ntfy user add --role=admin <admin>
kubectl exec -n ntfy deploy/ntfy -- ntfy access <admin> "heimdall-alerts" rw
kubectl exec -n ntfy deploy/ntfy -- ntfy token add <admin>
```

Record the token in the workspace secret store for the AlertManager Secret (Task C1).

- [ ] **Step 3: Commit** the README (`.commits/nidavellir-ntfy-readme.md`).

### Task B5: Wire the ntfy ArgoCD app

**Files:**
- Create: `components/nidavellir/apps/ntfy-app.yaml`
- Modify: `components/nidavellir/apps/kustomization.yaml`

- [ ] **Step 1: Write the Application** (mirror `heimdall-app.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ntfy
  namespace: argo
  annotations:
    argocd.argoproj.io/sync-wave: "6"   # after tailscale-operator (4), before/with heimdall (10)
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: 'http://gitea-http.gitea.svc.cluster.local:3000/nordri-admin/nidavellir.git'
    targetRevision: HEAD
    path: ntfy
  destination:
    server: https://kubernetes.default.svc
    namespace: ntfy
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
      - ServerSideApply=true
```

- [ ] **Step 2: Register** `- ntfy-app.yaml` in `apps/kustomization.yaml` (after `tailscale-operator-app.yaml`).
- [ ] **Step 3: Sync + verify on homelab (expect replicas: 0).**

```bash
kubectl annotate application nidavellir -n argo argocd.argoproj.io/refresh=hard --overwrite
kubectl get application ntfy -n argo
kubectl get deploy -n ntfy ntfy -o jsonpath='{.spec.replicas}'
```

Expected: app `Synced`; `ntfy` Deployment exists with `0` replicas (homelab cold standby). Confirm the Service has NO Tailscale annotations on homelab.

- [ ] **Step 4: Verify rendered GKE behavior** by reading the composition output for `$env == "gke"`: temporarily render with `crossplane render` (or read the template logic) and confirm `replicas: 1` + Tailscale annotations would apply. Document the check; do not commit a homelab override.
- [ ] **Step 5: Commit** (`.commits/nidavellir-ntfy-app.md`).

---

## Task Group C — AlertManager routing (heimdall composition)

### Task C1: Pre-create the AlertManager → ntfy webhook Secret

**Files:** none (out-of-band Secret in `heimdall` namespace).

- [ ] **Step 1: Decide the AlertManager→ntfy mechanism.** Default: AlertManager `webhook_configs` → ntfy publish endpoint with an `Authorization: Bearer <token>` header, using ntfy's per-topic publish. If header/format mapping is awkward, use the small `alertmanager`→`ntfy` bridge image. Spike: post a test message to ntfy with `curl` first (Step 2) to confirm the header/priority mapping, then choose.

```bash
curl -H "Authorization: Bearer <token>" -H "Priority: urgent" -H "Title: test" \
  -d "hello from heimdall" http://ntfy.<tailnet>.ts.net/heimdall-alerts
```

Expected: notification arrives on the subscribed phone.

- [ ] **Step 2: Create the Secret** holding the ntfy publish URL + token (and a placeholder Knarr webhook URL, Task D):

```bash
kubectl create namespace heimdall --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic ntfy-webhook -n heimdall \
  --from-literal=url="http://ntfy.<tailnet>.ts.net/heimdall-alerts" \
  --from-literal=token="<ntfy-token>"
```

### Task C2: Add the routing tree + receivers to the composition

**Files:**
- Modify: `components/heimdall/crossplane/composition.yaml` (the `alertmanager:` block at ~line 120)

- [ ] **Step 1: Extend the `alertmanager` block.** Add a `config:` alongside the existing `alertmanagerSpec:`:

```yaml
                alertmanager:
                  alertmanagerSpec:
                    resources:
                      requests:
                        cpu: 50m
                        memory: 64Mi
                      limits:
                        cpu: 250m
                        memory: 256Mi
                  config:
                    route:
                      group_by: ['alertname', 'namespace']
                      group_wait: 30s
                      group_interval: 5m
                      repeat_interval: 4h
                      receiver: ntfy-warning
                      routes:
                        - matchers: ['severity = "critical"']
                          receiver: ntfy-critical
                          repeat_interval: 1h
                    receivers:
                      - name: ntfy-warning
                        webhook_configs:
                          - url: "http://ntfy.ntfy.svc.cluster.local/heimdall-alerts"
                            send_resolved: true
                      - name: ntfy-critical
                        webhook_configs:
                          - url: "http://ntfy.ntfy.svc.cluster.local/heimdall-alerts"
                            send_resolved: true
                          # Knarr escalation seam (Task D) — dormant by default
```

Note: in-cluster AlertManager reaches ntfy via the in-cluster Service `ntfy.ntfy.svc.cluster.local` (works on GKE where ntfy is active; on homelab only when the standby is scaled up — matching the A3 fallback). Priority/title mapping headers depend on the C1 mechanism decision; if using raw `webhook_configs`, add `http_config`/headers or switch to the bridge as decided in C1.

- [ ] **Step 2: Validate parse.** Run: `kubectl apply --dry-run=client -f components/heimdall/crossplane/composition.yaml`. Expected: dry-run OK.
- [ ] **Step 3: Deploy + verify AlertManager loaded the config.**

```bash
# After ws push heimdall + update-embedded-git or ArgoCD resync on the cluster where ntfy is active:
kubectl exec -n heimdall sts/alertmanager-<release>-kube-promet-alertmanager-0 -- \
  amtool config show --alertmanager.url=http://localhost:9093
```

Expected: the `ntfy-critical`/`ntfy-warning` receivers and the `severity="critical"` route appear.

- [ ] **Step 4: Commit** (`.commits/heimdall-alertmanager-ntfy-routing.md`, `ws commit heimdall`).

---

## Task Group D — Knarr escalation seam (dormant)

### Task D1: Add the dormant webhook receiver + contract doc

**Files:**
- Modify: `components/heimdall/crossplane/composition.yaml` (the `ntfy-critical` receiver from C2)
- Modify: `components/heimdall/docs/architecture.md` (document the seam)

- [ ] **Step 1: Add a second `webhook_configs` entry** to the `ntfy-critical` receiver, pointing at a config-supplied Knarr URL that defaults to a disabled placeholder so no delivery is attempted until Knarr exists:

```yaml
                      - name: ntfy-critical
                        webhook_configs:
                          - url: "http://ntfy.ntfy.svc.cluster.local/heimdall-alerts"
                            send_resolved: true
                          {{- if .observed.composite.resource.spec.parameters.knarrWebhookUrl }}
                          - url: "{{ .observed.composite.resource.spec.parameters.knarrWebhookUrl }}"
                            send_resolved: true
                          {{- end }}
```

Add the `knarrWebhookUrl` parameter to `components/heimdall/crossplane/xrd.yaml` (string, no default). The `{{- if }}` gate omits the second webhook entirely when `knarrWebhookUrl` is unset — truly inert, with no placeholder URL and no delivery attempt. (Do **not** use `max_alerts: 0` as an "off" switch: in AlertManager that means *unlimited*, not disabled.)

- [ ] **Step 2: Document the contract** in `architecture.md`: the Knarr receiver consumes the standard AlertManager webhook v4 JSON payload at `knarrWebhookUrl`; Knarr implements a receiver to it for the SMS→call tier. Link the design doc.
- [ ] **Step 3: Validate parse** (`kubectl apply --dry-run=client` on both files).
- [ ] **Step 4: Verify dormancy.** With `knarrWebhookUrl` unset, confirm the rendered `ntfy-critical` receiver has only the ntfy webhook (the Knarr entry omitted by the `{{- if }}` gate — check the live AlertManager config via `amtool config show`). Expected: AlertManager healthy, no second webhook present.
- [ ] **Step 5: Commit** (`.commits/heimdall-knarr-seam.md`).

---

## Task Group E — End-to-end validation

### Task E1: Synthetic alert → phone (on the active cluster)

**Files:**
- Create (temporary, not committed): `/tmp/always-firing-rule.yaml`

- [ ] **Step 1: Apply an always-firing test rule** in the `heimdall` namespace on the cluster where ntfy is active:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: heimdall-alert-smoketest
  namespace: heimdall
  labels:
    release: <release>-kube-prometheus
spec:
  groups:
    - name: smoketest
      rules:
        - alert: HeimdallNotificationSmokeTest
          expr: vector(1)
          for: 0m
          labels: { severity: critical, component: heimdall }
          annotations: { summary: "ntfy delivery smoke test" }
```

- [ ] **Step 2: Wait for it to fire and route.** Expected: within ~1 min the `HeimdallNotificationSmokeTest` alert is `firing` in the AlertManager UI and routed to `ntfy-critical`.
- [ ] **Step 3: Confirm the phone receives it** with `urgent` priority (overrides DND). Expected: push notification arrives over Tailscale.
- [ ] **Step 4: Delete the test rule.** Run: `kubectl delete prometheusrule -n heimdall heimdall-alert-smoketest`. Confirm a `resolved` notification arrives (since `send_resolved: true`).

### Task E2: Cold-standby + Knarr-dormancy assertions

- [ ] **Step 1: Confirm homelab standby is at 0 replicas:** `kubectl get deploy -n ntfy ntfy -o jsonpath='{.spec.replicas}'` → `0`.
- [ ] **Step 2: Manually activate standby:** `kubectl scale deploy/ntfy -n ntfy --replicas=1`; confirm pod Ready; then scale back to 0. Expected: pod starts and stops cleanly (validates the standby manifest is real, just dormant).
- [ ] **Step 3: Confirm the Knarr seam is inert:** check AlertManager logs for no delivery attempts to the placeholder URL during the E1 smoke test. Expected: no errors, no Knarr delivery attempts.

### Task E3: Update the Thalamus arc

- [ ] **Step 1:** Append a note to the `heimdall-phase-2` arc in `hoards/thalami-Cervator/Loki-thalamus.md` recording that notification routing shipped (ntfy active GKE / standby homelab, Tailscale, Knarr seam dormant) and that automated failover + homelab-health alerting carry into the Uptime Kuma arc. (Thalamus is not committed to git.)

---

## Self-Review Notes

- **Spec coverage:** ntfy standalone app (B), Tailscale exposure (A), severity-tiered routing incl. DND override (C, E1), Knarr seam dormant (D), active/standby (B2/B5/E2), secrets via K8s Secret (A2/B4/C1), both-failure-direction handling (C deferral note + design). Email explicitly dropped (matches non-goal). Automated failover deferred to Uptime Kuma arc (matches non-goal).
- **Known spikes (accepted):** A1/A2/A3 (Tailscale mechanism + homelab egress), B2 Step 2 (ntfy image pin), C1 (AlertManager→ntfy header/bridge mechanism). Each has a concrete verify step before downstream tasks depend on it.
- **Type consistency:** XRD kind `XNtfy`/claim `Ntfy`; parameter names `replicasOverride`, `tailscaleHostname`, `baseUrl`, `knarrWebhookUrl` used consistently across B1/B2/B3/D1. Namespace `ntfy` and Service `ntfy.ntfy.svc.cluster.local` consistent across B2/C2/D1.
