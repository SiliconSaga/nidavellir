# Vegvísir Design

Vegvísir is the traffic director for the Nidavellir platform. Its primary goal is to provide a unified, "Goldilocks" routing architecture that behaves identically across different environments (GKE Public Cluster and K3s Homelab), minimizing configuration drift and cognitive load.

## Core Philosophy: "Traefik Everywhere"

To achieve parity between the GKE environment (where Gateways are typically hardware/cloud LBs) and the K3s environment (where Gateways are software), we standardize on **Traefik** as the Gateway Controller in all environments.

*   **GKE**: We bypass the native GKE Gateway Controller for application traffic. Instead, we install Traefik, which sits behind a single Google L4 Load Balancer. Use `gatewayClassName: traefik`.
*   **Homelab (K3s)**: We use the built-in Traefik (configured to enable Gateway API). Use `gatewayClassName: traefik`.

**Result**: `HTTPRoute` and `UDPRoute` manifests are identical across all environments.

## 1. Traefik Setup

### GKE Implementation
Traefik is installed via Helm to act as the Unified Gateway.

*   **Provider**: `kubernetesGateway` enabled.
*   **Service Type**: `LoadBalancer` (Provisions the single static IP/L4 LB).
*   **Ports**: Standard HTTP (80), HTTPS (443), and dynamic ranges for Game Servers.

### Homelab Implementation
K3s includes Traefik by default, but it may need reconfiguration to fully support the Gateway API.

*   **Mechanism**: `HelmChartConfig` manifest in `kube-system`.
*   **Config**: Explicitly enable `providers.kubernetesGateway`.

## 2. Cert-Manager Strategy

We adopt a "split-brain" issuer strategy to allow robust experimentation without breaking legacy Ingress-based services.

### GKE: DNS-01 wildcard (current)

*   **Issuer Name**: `letsencrypt-dns01`
*   **Solver**: `dns01` via Google Cloud DNS, authenticated by Workload Identity
    (no service-account key stored in-cluster).
*   **Certificate**: a single **wildcard** `*.cmdbee.org` (+ apex) cert, served
    by the shared Gateway's `websecure` listener as its only `certificateRef`.
*   **Why wildcard, not per-host**: Traefik's Gateway provider does not reliably
    serve more than one `certificateRef` on a listener (Traefik #11972). One
    wildcard cert = no cert-selection = reliable. Per-host `Certificate` +
    `ReferenceGrant` is retired.
*   **Traefik version**: pinned to 3.6.x — 3.7.x regressed Gateway-provider cert
    loading entirely. See `docs/wildcard-tls.md` and SiliconSaga/yggdrasil#65.
*   `letsencrypt-gateway` (HTTP-01) is kept only for the rare individual cert
    outside the wildcard domain.

### Homelab: Tunnel Strategy (Deferred)
*   **Current State**: Defer local cert management.
*   **Target Architecture**: **Tailscale Tunnel**.
    *   Traffic flows from User -> GKE (Termination) -> Tailscale -> Homelab.
    *   TLS is terminated at the GKE Gateway using the standard HTTP-01 flow.
    *   Homelab receives decrypted HTTP traffic through the tunnel.
    *   **Benefit**: Removes the need for DNS-01 challenges or exposing local ports (avoiding Namecheap IP whitelisting issues).

## 3. DNS

**Resolved (2026-05-18).** `cmdbee.org` DNS is hosted on **Google Cloud DNS**
(managed zone in the same GCP project as the cluster). DNS-01 cert issuance and
the wildcard cert are implemented — see §2 and `docs/wildcard-tls.md`.

Co-locating DNS in the cluster's GCP project is what enables the keyless
Workload Identity path for the cert-manager Cloud DNS solver. Per-record DNS
(apex + a `*.cmdbee.org` wildcard `A` → the Traefik LB) is managed in the
Cloud DNS zone.

### Historical note (superseded)

An earlier plan targeted NameCheap: a community ExternalDNS webhook for A-record
automation plus a Cloud NAT static egress IP to satisfy NameCheap's API
IP-allowlist, with HTTP-01 certs. That whole approach is moot — moving DNS to
Cloud DNS removed the IP-allowlist problem and gave a first-party cert-manager
solver. Recorded only so the reasoning isn't re-derived.

### Still open — A-record automation for new hosts

A new app today needs a DNS record (or the zone needs a `*.cmdbee.org` wildcard
`A`, which is currently in place — so subdomains resolve automatically). If
finer per-host record automation is wanted later, ExternalDNS with the Cloud DNS
provider (first-party, no webhook) is the clean path. Tracked under
SiliconSaga/yggdrasil#65.

## 4. The Vegvísir Operator

A custom Kubernetes controller is required to support the "Composed" architecture (Crossplane) without conflict.

### The Problem
When using Crossplane to provision dedicated Game Servers (via a `GameServerStack` XR), multiple servers need to expose different UDP ports on the same shared Gateway. Crossplane cannot safely manage a shared resource (the Gateway's `listeners` list) from multiple independent claims without race conditions or overwrites.

### The Solution: "Traffic Cop" Controller
Vegvísir acts as the operator that bridges the gap between individual Game Server routes and the shared Gateway.

*   **Input**: Watches for `UDPRoute` objects (or a specific `GameServerStack` status).
*   **Action**:
    1.  Detects a new Game Server requiring a specific port (e.g., `27015`).
    2.  Reads the shared `Gateway` resource.
    3.  **Hot-Patches** the Gateway's `listeners` list to include the new port if missing.
    4.  Traefik observes the Gateway update and opens the port.
*   **Safety**: Ensures atomic updates and prevents "fighting" over the listener list.

## Usage Workflow

 1.  **Pre-flight (one-time, manual)**:
     *   Install Gateway API CRDs on the cluster (`kubectl apply -f ...standard-install.yaml`).

 2.  **Layer 4 (Nordri — The Fundamentals)**:
     *   ArgoCD installs Traefik → GatewayClass `traefik` is registered.

 3.  **Layer 5 (Vegvísir — Platform Services)**:
     *   ArgoCD installs cert-manager (fresh clusters only; skip if pre-existing).
     *   ArgoCD applies the shared `Gateway` manifest → LoadBalancer IP provisioned.
     *   ArgoCD applies the `letsencrypt-dns01` ClusterIssuer and the wildcard
         `*.cmdbee.org` `Certificate` (see §2). The `letsencrypt-gateway`
         HTTP-01 issuer is also applied — retained for non-wildcard cases.
     *   ArgoCD installs Vegvísir Operator (TBD).

2.  **Application Layer (Crossplane/Agones)**:
    *   Developer commits a `GameServerStack` claim.
    *   Crossplane/Agones provisions the Pod and Service.
    *   Crossplane/Agones creates a `UDPRoute`.
    *   TODO: Figure out more exactly what Crossplane does vs Agones. It is probably Agones running the show in game server land.

3.  **Runtime**:
    *   Vegvísir Operator sees the `UDPRoute` -> Updates Gateway listeners.
    *   Traefik routes traffic -> Game On.
