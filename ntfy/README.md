# ntfy — Alert Notification Delivery

ntfy is the platform's notification-delivery layer: a self-hosted [ntfy](https://ntfy.sh) server that pushes alerts (initially Heimdall's AlertManager) to phones. It runs as a standalone Crossplane composition (not part of the Heimdall stack) so other sources — notably the future Knarr bridge — can reuse it.

Design + plan: [`docs/plans/2026-05-21-alert-notification-routing-design.md`](../docs/plans/2026-05-21-alert-notification-routing-design.md) and the companion `-plan.md`.

## What this deploys

- `xrd.yaml` / `composition.yaml` / `claim.yaml` — an `XNtfy`/`Ntfy` composite that renders the ntfy Deployment, Service, ConfigMap, and PVC via provider-kubernetes, env-aware off `EnvironmentConfig/cluster-identity`:
  - **GKE:** active (`replicas: 1`), Service exposed to the tailnet (device `ntfy-gke`).
  - **Homelab:** cold standby (`replicas: 0`), not tailnet-exposed (deferred — see Device naming).
- Deployed by ArgoCD via `../apps/ntfy-app.yaml` (sync-wave 6, after the Tailscale operator at wave 4).

## Reachability model

ntfy is reached over **Tailscale**, never a public endpoint. The Tailscale Kubernetes operator (`../apps/tailscale-operator-app.yaml`) joins the cluster to the tailnet and, for any Service annotated `tailscale.com/expose`, creates a proxy device with a MagicDNS name. Phones on the tailnet reach `http://ntfy-gke.<tailnet>.ts.net`; nothing is exposed publicly.

## Prerequisites: Tailscale setup

### 1. Install the Tailscale client (operator host / your devices)

Use the **official installer** from <https://tailscale.com/download> — Chocolatey/winget lag a few versions, and the official MSI bundles the GUI/tray components. After install, `tailscale up` opens a browser to log in.

**Login uses an external SSO provider (Google, GitHub, Microsoft) — Tailscale has no native account system, by design.** Sign in with whichever provider owns your tailnet (e.g. Google).

On Windows the CLI is added to PATH at install, but already-open shells won't see it until restarted; call it by full path (`"/c/Program Files/Tailscale/tailscale.exe"`) or open a new shell.

### 2. OAuth client for the operator

In the Tailscale admin console → Settings → OAuth clients, create a client with **both** of these scopes — both tagged `tag:k8s-operator`:

- **Devices → Core → write**
- **Auth Keys → write**  ← easy to miss; the operator mints its own auth key at startup, and without this scope it fails with `creating operator authkey: ... not enough permissions (403)`.

Save the client id/secret to the gitignored root `.env`:

```bash
export TS_OAUTH_CLIENT_ID=<id>
export TS_OAUTH_CLIENT_SECRET=<secret>
```

### 3. ACL: tag owners + access grant

In the policy editor:

```jsonc
"tagOwners": {
  "tag:k8s-operator": ["autogroup:admin"],
  "tag:ntfy":         ["tag:k8s-operator"]
},
"grants": [
  { "src": ["autogroup:member"], "dst": ["tag:ntfy"], "ip": ["80"] }
]
```

`tag:ntfy` must be owned by `tag:k8s-operator` so the operator may apply it to the ntfy proxy device. The grant lets your devices (incl. your phone) reach `tag:ntfy` on port 80. (Older tailnets use an `acls` block: `{"action":"accept","src":["autogroup:member"],"dst":["tag:ntfy:80"]}`.)

### 4. operator-oauth secret

The operator reads its creds from a Secret named `operator-oauth` in the `tailscale` namespace (keys `client_id` / `client_secret` — underscores). Create it from `.env`:

```bash
kubectl create namespace tailscale
kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id="$TS_OAUTH_CLIENT_ID" \
  --from-literal=client_secret="$TS_OAUTH_CLIENT_SECRET"
```

## Phone app

Install the **ntfy app** (iOS App Store / Google Play / F-Droid). The phone must be on the tailnet (Tailscale app installed + logged in). To subscribe:

1. In the ntfy app → "Subscribe to topic".
2. Set the **server** to the self-hosted URL — `http://ntfy-gke.<tailnet>.ts.net` — **not** the default `ntfy.sh` (the default public server won't see our self-hosted topics).
3. Topic: `heimdall-alerts`.

Critical alerts are published at ntfy priority `urgent`/max; warnings arrive as quiet pushes. Priority 5 is the strongest signal ntfy can send, but **piercing Do Not Disturb is an Android-side grant, not something priority alone achieves** — verified during homelab testing (a backgrounded phone in DND received the push silently). To let criticals interrupt DND, grant the ntfy app's max-priority channel the override: long-press an ntfy notification → Settings → the "Max priority (5)" channel → enable "Override Do Not Disturb" (or Settings → Notifications → Do Not Disturb → Apps → add ntfy). Only the max channel needs it, so warnings stay quiet. (ntfy auth: the composition sets `auth-default-access: deny-all`, so production subscriptions use an access token — see Secrets.)

### Android tuning (learned during homelab testing)

Android's notification controls have fanned out into per-channel sub-types, easy to lose in Settings. The reliable way in: **long-press a received ntfy notification → its gear/Settings**, rather than hunting blind through system Settings. Worth setting:

- **Grant the max-priority channel "Override Do Not Disturb"** (above) — criticals pierce DND, warnings stay quiet. Verified: under DND, the urgent push sounded and the default one stayed silent.
- **Disable notification "bundling"/grouping** for ntfy so alerts show individually rather than collapsed into a group.
- **Allow the app to run in the background** (exempt from battery optimization). Self-hosted ntfy has no Firebase/FCM path, so instant delivery relies on the app holding a persistent connection to the server; if Android sleeps the app, pushes are delayed until it next wakes.
- **Prefer WebSockets** for the subscription connection (the app suggests this) — the more efficient transport for that persistent connection. It passes through the Tailscale operator proxy fine (the WS upgrade is just HTTP over the forwarded TCP) and needs no server-side change; ntfy supports it natively.

## Device naming

- The exposed Service's proxy device is named per environment: `ntfy-<env>` → `ntfy-gke`. Distinct names avoid MagicDNS collisions during the active/passive failover window.
- **Homelab exposure is deferred.** When it lands (with the real 24/7 homelab box + the failover automation), name the homelab device **per box** (machine identity), not a generic `ntfy-homelab` — there are multiple resettable homelab boxes, and a reset box re-registers as a new device, so a generic name would collide/confuse.
- Give the **operator** a per-cluster hostname (`operatorConfig.hostname`, e.g. `tailscale-operator-gke`) once more than one cluster runs it, or the default `tailscale-operator` name collides across clusters.

## Gotchas

- **Tagged nodes show "Expiry disabled"** in the console — expected. Tailscale disables key expiry for tagged (infrastructure) devices so they don't get logged out on the user-device expiry cycle.
- **The operator's own device does not auto-remove on `helm uninstall`** — proxy devices clean up when their Service is deleted, but the operator node lingers and needs manual deletion (admin console, or `DELETE /api/v2/device/<id>`). Matters only on teardown; the operator runs persistently in normal use.

## Testing

- **Validate the OAuth credential directly** (no redeploy) by exchanging client-credentials for a token and minting a throwaway `tag:k8s-operator` auth key via the API — this exercises the exact `auth_keys` operation the operator needs and surfaces scope/tag problems immediately.
- **Smoke test** the full path by exposing a throwaway Service tagged `tag:ntfy` with a unique `ntfy-test-<timestamp>` name and curling it over the tailnet from any tailnet device, then tearing down and verifying no lingering devices.
- For **automated tests**, use `ntfy-test-<unique>` names plus **ephemeral** Tailscale nodes (so crashed-test stragglers auto-expire) plus explicit teardown — belt and suspenders against dirty tailnet state.

## Secrets

`operator-oauth` (Tailscale) and the ntfy access token live in Kubernetes Secrets per environment for now; migrate to OpenBAO when it ships, consistent with the Gitea-credentials trajectory.
