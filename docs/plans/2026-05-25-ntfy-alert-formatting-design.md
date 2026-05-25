# ntfy Alert Formatting & Priority (Templating) — Design

**Status:** Draft, ready for plan
**Date:** 2026-05-25
**Owner:** Rasmus Praestholm
**Related:** [Alert Notification Routing design](2026-05-21-alert-notification-routing-design.md) + [plan](2026-05-21-alert-notification-routing-plan.md) (this builds on the delivery layer they describe), [nidavellir #10](https://github.com/SiliconSaga/nidavellir/pull/10) (ntfy delivery layer), [heimdall #5](https://github.com/SiliconSaga/heimdall/pull/5) (AlertManager→ntfy routing), [ntfy message templating docs](https://docs.ntfy.sh/publish/#message-templating)

## Overview

The deployed delivery layer (nidavellir #10 / heimdall #5) works — real fired alerts reach the phone over Tailscale — but AlertManager's `webhook_configs` posts the raw AlertManager JSON at default priority, because AlertManager webhooks can't set ntfy's `Priority`/`Title`/`Tags` headers. Validated live on GKE, three pain points result: (1) **criticals don't pierce Do Not Disturb** (no `urgent` priority); (2) notifications are **unreadable raw-JSON blobs**; (3) **every** alert reaches the phone (a flood, since the GKE cluster has many firing alerts).

The original plan reserved a translator "bridge" component for this. Investigation found a lighter answer: **ntfy's native server-side message templating** maps severity→priority *and* formats the body, so v1 needs **no new component**. A throwaway test confirmed a `severity: critical` AlertManager payload renders `priority: 5` with a formatted title/message. The full rule-based multi-topic routing bridge stays deferred — templating can set title/message/priority but **not** topic or tags, so routing across topics still needs a real bridge when that need arrives.

## Goals

1. **Critical alerts pierce DND** — priority derived from `severity` (critical→5/urgent, warning→3, else→2).
2. **Readable notifications** — templated title + body from the AlertManager payload, not raw JSON.
3. **Tame the flood** — control *which* alerts reach the phone (AlertManager-side routing, since templating can't drop alerts).
4. **No new runtime component for v1** — ntfy templating + config only.
5. **Clear the auth drift** — replace the imperative `ntfy access` grant with declarative ntfy auth config.

## Non-goals

- **Rule-based routing across multiple ntfy topics.** Templating can't set topic/tags; deferred to a future bridge (own design) and only needed when, e.g., infra-vs-app belong on separate topics with separate subscriptions.
- **The Knarr SMS/call escalation tier.** Separate arc; the dormant webhook seam already exists in heimdall.
- **ntfy native Twilio calls.** ntfy can place phone calls via Twilio (`--twilio-*`), but Twilio is commercial — out of scope (the Knarr spare-phone bridge is the intended non-commercial escalation path).

## Architecture

### 1. ntfy server-side template (nidavellir composition)

ntfy loads **named templates** from `--template-dir` (default `/etc/ntfy/templates`, env `NTFY_TEMPLATE_DIR`), referenced per-publish by `?template=<name>`. Ship a `heimdall.yml` template via a ConfigMap mounted into the ntfy container at the template dir. The template maps the AlertManager webhook v4 JSON to ntfy fields (verified working against ntfy v2.23.0):

```yaml
title: "{{.commonLabels.alertname}} [{{.status}}]"
message: "{{range .alerts}}- {{.annotations.summary}}\n{{end}}"
priority: "{{if eq .commonLabels.severity \"critical\"}}5{{else if eq .commonLabels.severity \"warning\"}}3{{else}}2{{end}}"
```

| `severity` | ntfy priority | Behavior |
|---|---|---|
| `critical` | 5 (max/urgent) | Pierces DND (with the phone's max-channel override granted) |
| `warning` | 3 (default) | Normal push |
| other/unset | 2 (low) | Quiet |

Grouped alerts: AlertManager batches a group into one webhook; the template `range`s over `.alerts` to build a multi-line body — one notification per group.

### 2. AlertManager wiring (heimdall composition)

- Change the `webhook_configs` URL to `http://ntfy.ntfy.svc.cluster.local/heimdall-alerts?template=heimdall`.
- **Flood control lives here, not in the template** — templating formats whatever it's given; it can't drop alerts. Tighten the route tree so only actionable alerts reach the ntfy receivers (e.g. restrict to `severity =~ "critical|warning"` and lean on inhibit rules), filtering out the noisy/info-level legacy chatter seen on GKE.

### 3. Declarative ntfy auth (nidavellir composition)

Replace the imperative `ntfy access everyone heimdall-alerts rw` grant (drift, not in git) with ntfy's declarative config — `--auth-users` / `--auth-access` / `--auth-tokens` (env `NTFY_AUTH_*`) — so the deny-all default plus the `heimdall-alerts` topic grant are reproducible from the composition. Keeps the tailnet as the network perimeter while making the access model GitOps-managed.

## Data flow

```text
alert fires → Prometheus → AlertManager (groups, route-filters)
  → POST AlertManager JSON to ntfy  …/heimdall-alerts?template=heimdall
  → ntfy applies the heimdall template (severity→priority, formats title/body)
  → push to phone over Tailscale  (critical pierces DND)
```

## Components touched

- **nidavellir** ntfy composition: template ConfigMap + volume mount + `template-dir`; declarative auth config.
- **heimdall** composition: webhook URL `?template=heimdall`; route-tree filtering.

Both are small, declarative GitOps changes — no new Deployment/Service.

## Testing

- **Done (brainstorm):** throwaway ntfy + the AlertManager-shaped payload → confirmed `priority: 5` from `severity: critical`, formatted title/message.
- **Post-deploy:** re-subscribe the phone to `heimdall-alerts`; fire a synthetic `critical` PrometheusRule → confirm a readable notification that pierces DND; fire a `warning` → confirm a quiet push; confirm route-filtered/info alerts do **not** arrive.
- Validate the template + auth config render via `kubectl --dry-run=client` and a `crossplane render` (or live sync) check.

## Future Directions

- **Routing bridge** (own design) — a small custom service for rule-based routing across topics/tags, when multi-topic partitioning is wanted. Templating's topic/tags limitation is the trigger.
- **Knarr escalation** — implements the dormant heimdall webhook seam for the SMS→call tier.
