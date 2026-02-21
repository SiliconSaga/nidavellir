# Vegvísir

*The Navigation Compass*

Vegvísir is the routing abstraction layer for the Nidavellir platform. Its purpose is to provide standard, simple developer resources for exposing workloads (apps, game servers, APIs) to the network, hiding the complexity of the underlying infrastructure (like whether the cluster is running a Homelab Traefik instance or GKE Gateway).

## Exposing Applications & Domains

To expose an application to the internet, you typically need two things:
1. **Routing**: Directing external HTTP/TCP traffic to your internal Kubernetes Service.
2. **TLS/SSL**: Generating and automatically renewing a certificate so your application is served securely over HTTPS.

As the underlying infrastructure evolves (from Nginx Ingress to Traefik Gateway API), the resources you use to accomplish this will change.

### Option 1: The Classic Ingress Pattern (Current)

If your environment is still using the classic `Ingress` resource pattern (often backed by Nginx or older Traefik setups), your application simply needs an `Ingress` manifest.

**How it works:**
* The core platform (`Nordri`) runs `cert-manager` and provides a base `ClusterIssuer` (e.g., `letsencrypt-prod`).
* This `ClusterIssuer` is capable of fulfilling HTTP01 challenges for *any* domain pointing to the cluster.
* Your application claims a domain by annotating its `Ingress` with the name of the `ClusterIssuer`. `cert-manager` watches for these annotations to generate the certificate secret.

**Example `Ingress` Manifest:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    # This automatically requests a cert from the Nordri platform issuer
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: "nginx" # Or "traefik", depending on the active controller
  rules:
  - host: my-app.siliconsaga.org
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app-service
            port:
              number: 80
  tls:
  - hosts:
    - my-app.siliconsaga.org
    secretName: my-app-tls-secret # Cert-manager will create this secret
```

### Option 2: The Gateway API Pattern (Future state of Vegvísir)

Vegvísir is actively migrating toward the upstream Kubernetes **Gateway API** (`HTTPRoute`, `TCPRoute`, etc.), backed by Traefik.

**Does this change domain usage?**
Yes, slightly. The Gateway API separates the *infrastructure* (the Gateway) from the *routing* (the Route).

1. **The Gateway (Platform Layer)**: `Nordri` or `Vegvísir` creates a `Gateway` resource. This is where the `cert-manager` integration often happens (e.g., the Gateway might define that it listens on port 443 and terminates TLS using a wildcard cert, or it uses annotations to request certs).
2. **The HTTPRoute (App Layer)**: Your application no longer defines an `Ingress`. Instead, it defines an `HTTPRoute` that attaches to the shared platform Gateway.

**Example `HTTPRoute` Manifest:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: my-app
spec:
  parentRefs:
  - name: external-gateway # Attached to the Vegvisir/Traefik Gateway
    namespace: traefik
  hostnames:
  - "my-app.siliconsaga.org"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app-service
      port: 80
```

*(Note: Gateway API is still evolving. Check internal design docs for the specific Crossplane Compositions Vegvísir provides to template these routes).*

## Components

*(To be populated with the custom Vegvísir Operator source code)*
