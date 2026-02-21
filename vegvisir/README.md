# Vegvísir

*The Navigation Compass*

Vegvísir is the routing and TLS layer for the Nidavellir platform. It owns:

- **cert-manager** — installation manifest (for fresh clusters) and ClusterIssuer configuration
- **Traefik Gateway** — the shared `Gateway` resource that Traefik uses to provision the load balancer
- **Domain routing** — IngressRoute / HTTPRoute resources for platform services

It provides a unified ingress experience across environments, hiding whether the cluster
is a k3s homelab or a GKE public cluster. Nordri installs Traefik (the controller);
Vegvísir configures the Gateway and TLS layer on top of it.

## Prerequisites: Gateway API CRDs

The Gateway API CRDs are **not installed by default** on GKE (confirmed on 1.33.5) or
on k3s. Install them once before deploying Vegvísir:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

This installs `Gateway`, `GatewayClass`, `HTTPRoute`, `GRPCRoute`, and related CRDs.
Both Traefik's `kubernetesGateway` provider and cert-manager's `gatewayHTTPRoute`
solver require these CRDs to be present.

## cert-manager

Vegvísir owns cert-manager — its Helm install and its ClusterIssuers live here, not
in Nordri.

### Current State (Existing GKE Cluster)

cert-manager is already installed on the current cluster (managing `siliconsaga.org`
via nginx). Vegvísir skips reinstalling it and deploys only the new `Gateway` resource
and `letsencrypt-gateway` ClusterIssuer for the `cmdbee.org` domain.

The existing nginx-backed `letsencrypt-prod` ClusterIssuer on the cluster continues to
work for `siliconsaga.org` — Vegvísir does not touch it.

### Fresh Cluster Setup

When rebuilding the cluster from scratch, apply `manifests/cert-manager-app.yaml`
before the ClusterIssuer. Sync-wave ordering keeps everything in sequence:

```
Wave 1  — Nordri: Traefik installed → GatewayClass traefik registered
Wave 5  — Vegvísir: Gateway resource created → LoadBalancer IP provisioned
Wave 10 — Vegvísir: cert-manager installed (fresh cluster only)
Wave 15 — Vegvísir: ClusterIssuers applied
```

See `manifests/cert-manager-app.yaml`.

## Traefik Gateway

Vegvísir creates the shared `Gateway` resource (`traefik-gateway` in `kube-system`).

- **Nordri** installs Traefik → Traefik registers `GatewayClass: traefik`
- **Vegvísir** creates the `Gateway` → Traefik provisions the LoadBalancer

DNS for `cmdbee.org` is pointed at the LoadBalancer IP provisioned by this Gateway.
Retrieve the IP after deployment:

```bash
kubectl get gateway traefik-gateway -n kube-system \
  -o jsonpath='{.status.addresses[0].value}'
```

See `manifests/traefik-gateway.yaml`.

## ClusterIssuers

### letsencrypt-gateway (cmdbee.org → Traefik Gateway API)

Uses cert-manager's `gatewayHTTPRoute` HTTP-01 solver. When a `Certificate` is
requested referencing this issuer, cert-manager creates a temporary `HTTPRoute`
that routes the ACME challenge through the Traefik Gateway's HTTP (port 80) listener.

Use this issuer for any domain whose DNS points at the Traefik LoadBalancer IP.

See `manifests/letsencrypt-gateway-issuer.yaml`.

### letsencrypt-prod (siliconsaga.org → nginx — pre-existing, not managed here)

Already exists on the current cluster, backed by nginx. Kept in service while
migrating from nginx to Traefik. Once `siliconsaga.org` DNS moves to the Traefik
LoadBalancer IP, this issuer will be superseded by `letsencrypt-gateway`.

## Exposing Applications

### Option 1: Classic Ingress (siliconsaga.org — nginx, current)

Still active for existing `siliconsaga.org` services running behind nginx.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
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
    secretName: my-app-tls-secret
```

### Option 2: Gateway API (cmdbee.org — Traefik, current target)

For new services using the Gateway API pattern. HTTPRoutes attach to `traefik-gateway`
in `kube-system`. TLS is requested via a `Certificate` resource referencing
`letsencrypt-gateway`.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: my-app
spec:
  parentRefs:
  - name: traefik-gateway
    namespace: kube-system
  hostnames:
  - "my-app.cmdbee.org"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app-service
      port: 80
```

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: my-app
spec:
  secretName: my-app-tls-secret
  issuerRef:
    name: letsencrypt-gateway
    kind: ClusterIssuer
  dnsNames:
  - my-app.cmdbee.org
```

## Transitioning to GitHub

During bootstrap, ArgoCD pulls Nidavellir from the internal Gitea mirror (same as Nordri).
Once the cluster is stable and Vegvísir is healthy, you can transition ArgoCD to pull
future updates directly from the GitHub source — so a push to GitHub is all you need for
ongoing GitOps.

### Step 1: Add GitHub credentials to ArgoCD

Create an ArgoCD repository credential Secret. Use a GitHub personal access token (PAT)
with `Contents: read` scope (classic: `repo`):

```bash
kubectl create secret generic nidavellir-github-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/SiliconSage/nidavellir.git \
  --from-literal=username=token \
  --from-literal=password=<your-github-pat>

kubectl label secret nidavellir-github-repo -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### Step 2: Update the Vegvísir Application source

In the **Nordri** repo, edit `platform/argocd/vegvisir-app.yaml` and change `repoURL`:

```yaml
repoURL: 'https://github.com/SiliconSage/nidavellir.git'
```

Commit and push to the Nordri Gitea. ArgoCD picks up the change, re-registers the
Vegvísir Application against GitHub, and Nidavellir changes from GitHub are live.

### Notes

- The same swap pattern can be applied to the Nordri repo itself later.
- The internal Gitea remains available as a fallback if GitHub is unreachable.

## Components

*(Vegvísir Operator — custom controller for shared Gateway UDP port management — TBD)*
