# Alert Notification Routing (ntfy) — Design

**Status:** Draft, ready for plan
**Date:** 2026-05-21
**Owner:** Rasmus Praestholm
**Related:** [Heimdall Phase 2 Monitoring Design](https://github.com/SiliconSaga/yggdrasil/blob/main/docs/plans/2026-05-19-heimdall-monitoring-design.md) (this arc fulfills its "AlertManager notification routing" non-goal), [Heimdall Architecture](https://github.com/SiliconSaga/heimdall/blob/main/docs/architecture.md), [Heimdall PR #4](https://github.com/SiliconSaga/heimdall/pull/4) (shipped the self-health PrometheusRules whose alerts currently route nowhere)

## Overview

Heimdall PR #4 shipped self-health PrometheusRules (PVC-fill, restart-storm, WAL/TSDB corruption) and they fire correctly into AlertManager — but AlertManager has no receiver configured, so alerts stop there. They are visible in the Prometheus/AlertManager UI and nowhere else. This arc adds the delivery layer: a self-hosted [ntfy](https://ntfy.sh) server that pushes alerts to a phone, with priority-tiered routing so criticals can override Do Not Disturb. It also designs (but does not build) the seam through which the future Knarr project will add an SMS/phone-call escalation tier.

The guiding principle, inherited from the monitoring design's "watcher independent from the watched": an environment's alert *delivery* must not depend on that environment being healthy. The arc realizes a first cut of that with an active hub on GKE and a cold standby on homelab, and defers the automated failover to the Uptime Kuma cross-watchdog arc, which already owns homelab↔GKE cross-probing.

## Goals

1. **Critical alerts reliably reach the operator's phone** — including the ability to override silent/DND, which plain email cannot guarantee.
2. **Self-hosted, nothing publicly exposed** — delivery transits the operator's existing Tailscale tailnet, consistent with the proven Matrix-over-Tailscale pattern.
3. **Reusable delivery layer** — ntfy is a standalone platform service, not embedded in the Heimdall observability stack, so other alert sources (notably Knarr) can consume it.
4. **Designed-in escalation seam** — the AlertManager → Knarr webhook contract is defined and documented now, so the future SMS/call tier slots in without re-touching AlertManager.
5. **Delivery survives a single-environment failure** — active hub on always-on GKE, cold standby definition on homelab, with a documented manual activation path.

## Non-goals

- **Automated failover** (homelab watchdog pings GKE ntfy, auto-spins the standby on failure). Folds into the Uptime Kuma cross-watchdog arc — that arc already does homelab↔GKE pinging, so the failover trigger belongs there, not here. v1 ships the cold standby as a manually-activated `replicas: 0` definition.
- **Knarr SMS/phone-call implementation.** This arc defines and documents the webhook seam and ships it dormant; Knarr implements *to* the contract later.
- **Email tier.** Push with priority tiers replaces it; email's "lost in inbox" failure mode is the problem we're solving, not a fallback to preserve.
- **OIDC/SSO on ntfy.** Access-token auth for v1; OIDC folds into the broader Phase 2 Keycloak item.
- **ntfy multi-tenancy hardening.** See Future Directions — tenancy is a real eventual need (Knarr) but v1 uses a single admin + topic-scoped access tokens.

## Architecture

### Component boundary

ntfy is a **standalone Nidavellir platform app**, deployed by ArgoCD, not part of the `HeimdallStack` Crossplane composition. Heimdall's only change is AlertManager configuration that points at ntfy. This keeps "detect" (Heimdall) separate from "deliver" (ntfy) and lets Knarr reuse the same server. The boundary is a well-defined interface: AlertManager (and later Knarr) publish to ntfy's HTTP API; ntfy owns delivery to subscribed devices.

### Topology & data flow

```text
GKE (always-on anchor)                      Homelab (experimental, intermittent)
  Prometheus → AlertManager ─┐                Prometheus → AlertManager ─┐
                             │                                          │
                  GKE ntfy (ACTIVE) ◀─────── (tailnet) ─────────────────┘
                             │                ntfy (COLD STANDBY, replicas: 0)
                             │
                    (Tailscale tailnet)
                             │
                        Operator phone (ntfy app, subscribed to GKE topic)
```

- GKE AlertManager → GKE ntfy via in-cluster Service.
- Homelab AlertManager → GKE ntfy via the tailnet address.
- Phone subscribes to the GKE ntfy topic over Tailscale; nothing is published to a public endpoint.

### GKE ntfy exposure

Tailscale. ntfy joins the tailnet (Tailscale operator on GKE, or a sidecar/subnet-router), so homelab→GKE and phone→GKE share one private path and no public ingress is added. Decision rationale: matches the operator's already-proven nothing-exposed Matrix pattern; the cost is standing up Tailscale on GKE. (Rejected alternative: the existing `*.cmdbee.org` wildcard TLS + ntfy access token — public but authed, zero new infra — kept on file if Tailscale-on-GKE proves heavy.)

### AlertManager routing (Heimdall-side change)

The routing tree lives in the heimdall composition's kube-prometheus-stack values, branching on the `severity` label the PR #4 rules already set:

- `severity: critical` → ntfy receiver, priority `urgent`/max (overrides silent/DND) **and** the Knarr escalation seam (dormant).
- `severity: warning` → ntfy receiver, priority `default`/low (quiet push).

The ntfy receiver uses AlertManager's `webhook_configs` to reach ntfy — either directly against ntfy's HTTP publish API or via a small `alertmanager`→`ntfy` bridge (exact mechanism is a plan-phase decision) — mapping severity → ntfy `Priority`, plus `Title`/`Tags` for readable phone notifications.

### Knarr escalation seam

A second `webhook_configs` on the critical route, URL sourced from config/Secret, defaulting to disabled/placeholder. Contract: the standard AlertManager webhook v4 JSON payload. Documented so Knarr implements a receiver to it for the future SMS → high-urgency-call escalation chain. Nothing is built in this arc beyond the defined-but-off receiver and the written contract.

### Failover and the two failure directions

The two environment-failure directions are asymmetric because the active hub lives on GKE:

- **Homelab fails** — the easy direction. GKE cross-probes homelab over the tailnet (Uptime Kuma arc) and alerts via the GKE-resident active ntfy hub. Both the watcher and the delivery path are independent of the failed environment, so no special machinery is needed. *Caveat:* homelab is intentionally intermittent today (two boxes up "most of the time," a true-24/7 Linux box planned later), so "homelab down" is usually expected, not an incident. Homelab-health alerting must be suppressed or scoped until the formal 24/7 primary exists, or it will page on every routine shutdown and get muted. This is an Uptime Kuma arc concern, recorded here so it is not lost.
- **GKE fails** — the hard direction, because the active hub is the casualty. v1 handles it manually: if GKE ntfy is unreachable, the operator scales up the homelab standby (`replicas: 0` → `1`) and the phone receives via the homelab topic over the tailnet. Duplicate notifications during the incident window are acceptable. Phase B (Uptime Kuma arc): a homelab watchdog probes GKE ntfy `/v1/health` and auto-activates the standby on failure.

**Synergy with the monitoring arc:** the monitoring design deferred GKE→homelab probing "until the network link decision is made." This arc makes that decision (Tailscale on GKE), so the GKE→homelab watch capability — the thing that catches a homelab failure — becomes available as a side effect of standing up ntfy delivery.

### Secrets

ntfy access token, Tailscale auth key, and the future Knarr webhook token live in a Kubernetes Secret per environment. OpenBAO when it ships (consistent with the Gitea-credentials trajectory).

## Testing

- Fire a synthetic always-firing alert (a test PrometheusRule or `amtool`) on each cluster; confirm the phone receives it over Tailscale.
- Verify a `critical` alert overrides phone DND/silent; verify `warning` arrives as a quiet push.
- Verify the homelab standby manifest renders but runs at 0 replicas; manually scale to 1 and confirm delivery, then scale back.
- Verify the Knarr webhook receiver is defined but dormant (no delivery attempts when the URL is the placeholder/disabled).

## Future Directions

- **ntfy multi-tenancy (Knarr).** ntfy supports per-topic access control and tokens. As Knarr comes online, ntfy graduates from a single-admin Heimdall-alert server to a multi-tenant delivery layer — topics/ACLs scoped per consumer (Heimdall alerts vs Knarr bridging traffic). This is the reusability payoff that justifies the standalone-component boundary.
- **Automated active/passive failover** via the Uptime Kuma watchdog (Phase B above).
- **Knarr SMS/phone-call escalation** implementing the webhook contract — the spare-phone bridge becomes the telephony tier without a commercial provider.
