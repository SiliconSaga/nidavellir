# ntfy Alert Formatting & Priority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Heimdall's alerts arrive on the phone readable and severity-prioritized (critical pierces DND, warning stays quiet) by adding ntfy server-side templating, declarative ntfy auth, and AlertManager route-filtering — no bridge component.

**Architecture:** A named ntfy template (`heimdall.yml`) shipped via a ConfigMap and mounted into the ntfy container's `--template-dir`; AlertManager posts to `…/heimdall-alerts?template=heimdall` so ntfy maps `severity`→priority and formats title/body. ntfy auth becomes declarative (`auth-access` in `server.yml`, replacing the imperative grant). AlertManager's route tree is tightened so only `critical`/`warning` reach ntfy.

**Tech Stack:** Crossplane (function-go-templating, provider-kubernetes Objects), ntfy v2.23.0 server-side message templating, Prometheus AlertManager (kube-prometheus-stack), ArgoCD.

**Design:** [2026-05-25-ntfy-alert-formatting-design.md](2026-05-25-ntfy-alert-formatting-design.md)

**Conventions (read before starting):**
- Commits via `ws commit <comp> <bodyfile>` (never raw git); a `.commits/<name>.md` bodyfile with `message:` + `add:` frontmatter. Push via `ws push <comp>`.
- Two components, so likely two PRs: **nidavellir** (template + declarative auth — Tasks A, B) and **heimdall** (AlertManager wiring — Task C). nidavellir lands first (heimdall's `?template=heimdall` depends on the template existing).
- "Tests" are `kubectl --dry-run=client` parse checks + live-deploy verification on GKE (where ntfy is active) + a throwaway-ntfy template check. The composites only render correctly on a cluster, so most verification is post-deploy.
- File paths are workspace-root-relative (agents work from the yggdrasil root via `ws exec`).
- Branch: nidavellir work goes on `feat/ntfy-alert-formatting` (already created off main).

---

## File Structure

**New — nidavellir (`feat/ntfy-alert-formatting`):**
- `ntfy/heimdall-template.yaml` — a standalone `ntfy-templates` ConfigMap (plain manifest, applied by ArgoCD, **not** go-templated by the composition — so no brace-escaping). Holds the `heimdall.yml` ntfy template.

**Modified — nidavellir:**
- `ntfy/composition.yaml` — mount the `ntfy-templates` ConfigMap into the ntfy Deployment at `/etc/ntfy/templates`; add `auth-access` to the `ntfy-server-config` `server.yml`.
- `ntfy/README.md` — document the template + declarative-auth (replaces the imperative `ntfy access` note).

> **Why a standalone manifest for the template (not inside the composition):** the composition's `template: |` body is itself rendered by function-go-templating, so any `{{.commonLabels...}}` in an in-composition ConfigMap would be evaluated (and emptied) unless wrapped in fragile `{{` literal-brace `}}` escaping. The ntfy template is static (no env-awareness), so it ships as a plain ConfigMap that ArgoCD applies directly — the braces reach the cluster verbatim, no escaping. The `ntfy-server-config` ConfigMap stays *in* the composition because it needs the `{{ if $params.baseUrl }}` logic.

**Modified — heimdall (new branch `feat/alertmanager-template-routing`):**
- `crossplane/composition.yaml` — append `?template=heimdall` to both ntfy webhook URLs; tighten the route tree (default → `null` blackhole; `critical`→`ntfy-critical`, `warning`→`ntfy-warning`).
- `docs/architecture.md` — update the Alerting & Notification section to reflect that priority/formatting are now active.

---

## Task A: ntfy server-side template (nidavellir)

**Files:**
- Create: `components/nidavellir/ntfy/heimdall-template.yaml` (standalone ConfigMap)
- Modify: `components/nidavellir/ntfy/composition.yaml` (Deployment volume/mount)

- [ ] **Step 1: Create the standalone template ConfigMap** `components/nidavellir/ntfy/heimdall-template.yaml`. Plain manifest — ArgoCD applies it directly, so the braces are NOT go-template-evaluated (no escaping). Uses the verified template (a `critical` payload renders `priority: 5`):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ntfy-templates
  namespace: ntfy
data:
  heimdall.yml: |
    title: "{{.commonLabels.alertname}} [{{.status}}]"
    message: "{{range .alerts}}- {{.annotations.summary}}\n{{end}}"
    priority: "{{if eq .commonLabels.severity \"critical\"}}5{{else if eq .commonLabels.severity \"warning\"}}3{{else}}2{{end}}"
```

(The `ntfy` ArgoCD app's source path is the `ntfy/` directory, so this manifest is applied to the `ntfy` namespace alongside the XRD/Composition/Claim — no escaping, no composition change for the template content itself.)

- [ ] **Step 2: Mount the templates ConfigMap** into the ntfy Deployment. In `ntfy/composition.yaml`, add a volumeMount and volume to the `ntfy` container (alongside the existing `config` and `data` entries):

volumeMount (under `volumeMounts:`):
```yaml
                        - name: templates
                          mountPath: /etc/ntfy/templates
```
volume (under `volumes:`):
```yaml
                      - name: templates
                        configMap:
                          name: ntfy-templates
```
(`/etc/ntfy/templates` is ntfy's default `--template-dir`, so no `server.yml` change is needed to load it. If the Deployment pod starts before ArgoCD applies the ConfigMap, the mount retries — eventually consistent.)

- [ ] **Step 3: Validate parse.** Run each separately: `kubectl apply --dry-run=client -f components/nidavellir/ntfy/heimdall-template.yaml` (expect `configmap/ntfy-templates created (dry run)`) and `kubectl apply --dry-run=client -f components/nidavellir/ntfy/composition.yaml` (expect dry-run OK).

- [ ] **Step 4: Verify the template renders correctly** with a throwaway local ntfy (the template logic, independent of k8s). Extract the `heimdall.yml` data into `.tmp/ntfy-templates/heimdall.yml` and POST a sample AlertManager payload (`.tmp/am-sample.json` — a v4 webhook with `commonLabels.severity: critical` and an `alerts[]` entry):
```bash
docker run -d --name ntfy-tpl -p 8099:80 binwiederhier/ntfy:v2.23.0 serve
MSYS_NO_PATHCONV=1 docker cp .tmp/ntfy-templates/heimdall.yml ntfy-tpl:/etc/ntfy/templates/heimdall.yml
docker restart ntfy-tpl
curl -sS --retry 5 --retry-all-errors -X POST --data-binary @.tmp/am-sample.json "http://localhost:8099/t?template=heimdall"
docker rm -f ntfy-tpl
```
Expected: the response JSON shows `"priority":5`, a formatted `title`, and a `message` built from `alerts[]`. (Already confirmed once during brainstorming; re-run if the template content changed.)

- [ ] **Step 5: Commit.** Bodyfile `.commits/nidavellir-ntfy-template.md` (`add: [ntfy/heimdall-template.yaml, ntfy/composition.yaml]`), `message: "feat(ntfy): ship heimdall server-side template (severity→priority + formatting)"`. Run `bash scripts/ws commit nidavellir .commits/nidavellir-ntfy-template.md`.

---

## Task B: Declarative ntfy auth (nidavellir)

**Files:**
- Modify: `components/nidavellir/ntfy/composition.yaml` (the `ntfy-server-config` `server.yml`)
- Modify: `components/nidavellir/ntfy/README.md`

- [ ] **Step 1: Add declarative `auth-access` to `server.yml`.** In the `ntfy-server-config` ConfigMap data (currently ends with `behind-proxy: true`), add a declarative grant so the deny-all default is paired with an explicit anonymous read-write grant on the `heimdall-alerts` topic — replacing the imperative `ntfy access` command:

```yaml
                    auth-file: "/var/lib/ntfy/user.db"
                    auth-default-access: "deny-all"
                    auth-access:
                      - "everyone:heimdall-alerts:rw"
                    cache-file: "/var/lib/ntfy/cache.db"
                    behind-proxy: true
```

- [ ] **Step 2: Verify the declarative-auth token format** against ntfy v2.23.0 (the `everyone` vs `*` user identifier and the `rw` permission code), reusing the Task A throwaway container approach but with the auth config. Run a local ntfy with the `server.yml` above + `auth-file`, then confirm an anonymous publish to `heimdall-alerts` succeeds and a publish to a *different* topic is denied:
```bash
# (write the server.yml with auth-access to .tmp/ntfy-auth/server.yml, mount/cp it, run serve)
curl -sS -o /dev/null -w "%{http_code}\n" -d "test" http://localhost:8099/heimdall-alerts   # expect 200
curl -sS -o /dev/null -w "%{http_code}\n" -d "test" http://localhost:8099/other-topic        # expect 403
```
Expected: 200 for `heimdall-alerts`, 403 for `other-topic`. If `everyone` is rejected, try `*` (the anonymous identifier the imperative grant displayed) and use whichever works. Record the working form.

- [ ] **Step 3: Validate parse.** Run: `kubectl apply --dry-run=client -f components/nidavellir/ntfy/composition.yaml`. Expected: dry-run OK.

- [ ] **Step 4: Update `ntfy/README.md`.** Replace the "imperative `ntfy access` grant for the test" note in the Testing/Secrets sections with the declarative `auth-access` approach (deny-all default + the in-composition `auth-access` grant on `heimdall-alerts`). Note the tailnet remains the network perimeter.

- [ ] **Step 5: Commit.** Bodyfile `.commits/nidavellir-ntfy-declarative-auth.md` (`add: [ntfy/composition.yaml, ntfy/README.md]`), `message: "feat(ntfy): declarative auth-access for heimdall-alerts (replace imperative grant)"`.

---

## Task C: AlertManager template URL + route filtering (heimdall)

**Prereq:** Task A merged (or hydrated) so the `heimdall` template exists on the ntfy server. Work on a new heimdall branch `feat/alertmanager-template-routing` off heimdall main.

**Files:**
- Modify: `components/heimdall/crossplane/composition.yaml` (the `alertmanager.config` route + receiver URLs)
- Modify: `components/heimdall/docs/architecture.md`

- [ ] **Step 1: Append `?template=heimdall` to both ntfy webhook URLs.** In the `ntfy-warning` and `ntfy-critical` receivers, change `url: "http://ntfy.ntfy.svc.cluster.local/heimdall-alerts"` → `url: "http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall"` (both occurrences; leave the if-gated Knarr webhook URL unchanged).

- [ ] **Step 2: Tighten the route tree for flood control.** Change the default route to a `null` blackhole and route only `warning`/`critical` to ntfy. Replace the `route:` block:

```yaml
                    route:
                      group_by: ['alertname', 'namespace']
                      group_wait: 30s
                      group_interval: 5m
                      repeat_interval: 4h
                      receiver: 'null'
                      routes:
                        - matchers: ['severity = "critical"']
                          receiver: ntfy-critical
                          repeat_interval: 1h
                        - matchers: ['severity = "warning"']
                          receiver: ntfy-warning
```
And add a `null` receiver to the `receivers:` list (a receiver with no integrations = blackhole):
```yaml
                      - name: 'null'
```

- [ ] **Step 3: Validate parse.** Run: `kubectl apply --dry-run=client -f components/heimdall/crossplane/composition.yaml`. Expected: dry-run OK.

- [ ] **Step 4: Update `docs/architecture.md`.** In the Alerting & Notification section, change the "Current limitation" wording to reflect that severity→priority + formatting are now active via the `?template=heimdall` server-side template, and that non-`critical`/`warning` alerts are blackholed (flood control). Update the roadmap bullet accordingly.

- [ ] **Step 5: Commit.** Bodyfile `.commits/heimdall-alertmanager-template-routing.md` (`add: [crossplane/composition.yaml, docs/architecture.md]`), `message: "feat(observability): route AlertManager to ntfy ?template=heimdall + filter to critical/warning"`.

---

## Task D: End-to-end validation on GKE

**Prereq:** Tasks A+B merged to nidavellir main and Task C merged to heimdall main (or hydrated to GKE Seed Gitea). ntfy is active on GKE.

- [ ] **Step 1: Deploy.** Switch kubectl context to GKE deliberately. Hydrate via `GITEA_HOST=gitea.cmdbee.org GITEA_SCHEME=https bash scripts/ws exec nordri ./update-embedded-git.sh gke` (or rely on ArgoCD auto-sync from GitHub after merge). Hard-refresh the `ntfy` and `heimdall` ArgoCD apps.
- [ ] **Step 2: Confirm the template ConfigMap applied + is mounted.** `kubectl get configmap ntfy-templates -n ntfy -o jsonpath='{.data.heimdall\.yml}'` — expect the literal template with real `{{.commonLabels.alertname}}` (guaranteed, since it's a plain ArgoCD-applied manifest, not go-templated). Then `MSYS_NO_PATHCONV=1 kubectl exec -n ntfy deploy/ntfy -- ls /etc/ntfy/templates` — expect `heimdall.yml`.
- [ ] **Step 3: Confirm declarative auth.** `kubectl exec -n ntfy deploy/ntfy -- ntfy access` — expect the `everyone`/`*` → `heimdall-alerts` rw entry present *without* any manual `ntfy access` command having been run.
- [ ] **Step 4: Re-subscribe the phone** to `heimdall-alerts` on `http://ntfy-gke.tailf5b47a.ts.net` (anonymous; granted declaratively).
- [ ] **Step 5: Fire test alerts.** Apply an always-firing `critical` PrometheusRule (labels `severity: critical`, `release: <release>-kube-prometheus`); confirm the phone gets a **readable** (templated title/body) notification that **pierces DND**. Apply a `warning` rule; confirm a quiet readable push. Apply an `info`/no-severity rule; confirm it does **NOT** arrive (blackholed). Delete the test rules.
- [ ] **Step 6: Update the Thalamus arc** `ntfy-notification-routing` next-field (succinct) to record formatting/priority shipped; note the routing-bridge + Knarr tiers as the remaining future work.

---

## Self-Review

- **Spec coverage:** template+priority (Task A), declarative auth replacing the imperative grant (Task B), `?template=` URL + flood-control route filtering (Task C), end-to-end + DND verification (Task D). All design goals mapped.
- **Known verify-first items (not placeholders):** the ntfy template renders priority from severity (A4 confirms — already done once in brainstorming); the ntfy `auth-access` token format `everyone` vs `*` (B2 confirms). Both have explicit verification steps with expected output. The standalone-manifest approach (Task A) removed the earlier brace-escaping fragility.
- **Deferred (per design, not in this plan):** the rule-based multi-topic routing bridge; the Copilot-suggested kuttl test asserting the rendered AlertManager routing (best added here once the config stabilizes — consider folding into Task C as a follow-up).
- **Type/name consistency:** ConfigMap `ntfy-templates`, mount `/etc/ntfy/templates`, template name `heimdall` (→ `?template=heimdall`), topic `heimdall-alerts`, receivers `null`/`ntfy-warning`/`ntfy-critical` consistent across Tasks A/C/D.
