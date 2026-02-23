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

### GKE: HTTP-01 with Gateway
*   **Issuer Name**: `letsencrypt-gateway`
*   **Solver**: `http01` using `gatewayHTTPRoute`.
*   **Configuration**:
    *   The solver is defined in the `ClusterIssuer`, not on the Gateway itself.
    *   When a `Certificate` references this issuer, cert-manager creates a temporary
        `HTTPRoute` that routes the ACME HTTP-01 challenge through the Traefik Gateway's
        port-80 listener. No annotations on the Gateway are needed.
    *   Prerequisite: Gateway API CRDs must be installed on the cluster (see README).

### Homelab: Tunnel Strategy (Deferred)
*   **Current State**: Defer local cert management.
*   **Target Architecture**: **Tailscale Tunnel**.
    *   Traffic flows from User -> GKE (Termination) -> Tailscale -> Homelab.
    *   TLS is terminated at the GKE Gateway using the standard HTTP-01 flow.
    *   Homelab receives decrypted HTTP traffic through the tunnel.
    *   **Benefit**: Removes the need for DNS-01 challenges or exposing local ports (avoiding Namecheap IP whitelisting issues).

## 3. DNS Automation (TODO)

**Goal**: Fully automate the DNS A record creation and cert issuance for any domain
pointed at the Traefik Gateway, so a user with a NameCheap account and API credentials
gets zero-touch domain wiring after bootstrap.

### Current state
The bootstrap script prints the Traefik LB IP and tells the user to go set A records
manually at their registrar. cert-manager then uses HTTP-01, which requires DNS to
already be propagated before cert issuance can begin.

### Target architecture (GKE + NameCheap)

**Problem: NameCheap API IP whitelisting**
NameCheap's API requires callers to be from a pre-whitelisted IP. GKE node IPs are
ephemeral and change on cluster reset — making whitelisting impractical without a
stable egress IP.

**Solution: Cloud NAT with a static egress IP**
Add a Cloud NAT configuration in `gke-provision.sh` that routes all cluster outbound
traffic through a reserved static IP. The user whitelists that one IP in NameCheap
once; it survives cluster resets.

```
gke-provision.sh create  →  also reserves a static IP + creates Cloud NAT
gke-provision.sh delete  →  also releases the static IP
```

**ExternalDNS for A record automation**
Deploy ExternalDNS as a Nidavellir/Vegvísir component. It watches the Traefik
LoadBalancer Service and automatically creates/updates A records via the NameCheap
API. Provider: ExternalDNS 0.14+ supports third-party webhook providers; a community
NameCheap webhook exists (evaluate maintenance status before adopting).

Credentials: NameCheap API key + username stored as a Secret (OpenBAO long-term).

**DNS-01 challenge (optional upgrade)**
Switch cert-manager from HTTP-01 to DNS-01 using the same NameCheap API credentials.
Benefits:
- Cert issuance no longer depends on DNS propagation timing
- Wildcard certificates become possible (`*.cmdbee.org`)
- The ClusterIssuer solver changes from `gatewayHTTPRoute` to `webhook` (NameCheap)

DNS-01 is more powerful but adds a second NameCheap API dependency on the cert-manager
side; evaluate whether ExternalDNS alone (plus HTTP-01) is sufficient first.

### Open questions
- Maintain the Cloud NAT static IP across cluster resets, or require a one-time setup
  step outside of gke-provision.sh?
- Which NameCheap ExternalDNS webhook to adopt? Needs maintenance/activity check.
- Make NameCheap automation optional (flag in bootstrap or separate step) so the
  flow still works for users with other registrars or manual DNS preferences.

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
     *   ArgoCD applies `letsencrypt-gateway` ClusterIssuer.
     *   ArgoCD installs Vegvísir Operator (TBD).

2.  **Application Layer (Crossplane/Agones)**:
    *   Developer commits a `GameServerStack` claim.
    *   Crossplane/Agones provisions the Pod and Service.
    *   Crossplane/Agones creates a `UDPRoute`.
    *   TODO: Figure out more exactly what Crossplane does vs Agones. It is probably Agones running the show in game server land.

3.  **Runtime**:
    *   Vegvísir Operator sees the `UDPRoute` -> Updates Gateway listeners.
    *   Traefik routes traffic -> Game On.
