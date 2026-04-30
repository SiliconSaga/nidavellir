# Cluster Identity Demo

A minimal Crossplane Composition that exercises the
[cluster-identity pattern](https://github.com/SiliconSaga/nordri/blob/main/docs/cluster-identity.md)
end-to-end on a live cluster: it deploys a `traefik/whoami` echo service
behind a `Certificate` + `HTTPRoute`, with the hostname built from
`EnvironmentConfig/cluster-identity` (loaded into the pipeline by
`function-environment-configs`).

It's a substrate smoke test, not a workload — useful when you want to verify
that:

- `function-environment-configs` is healthy and the EnvironmentConfig fields
  flow into a downstream `function-go-templating` step
- The Traefik Gateway and cert-manager pipeline accept a Crossplane-rendered
  `Certificate` + `HTTPRoute` pair
- Per-environment defaulting actually produces the expected hostname for
  this cluster (`ci-demo.cmdbee.org` on GKE, `ci-demo.homelab.local` on
  homelab)

## How it's wired

| Resource | Purpose |
|----------|---------|
| `xrd.yaml` | `XClusterIdentityDemo` API. Required: `subdomain`. Optional: `domain` (override), `issuer` (defaults to `letsencrypt-gateway-staging`). |
| `composition.yaml` | Pipeline: `load-cluster-identity` → render `Deployment` + `Service` → render `Certificate` + `HTTPRoute` → `auto-ready`. |
| `claim.yaml` | Sample `ClusterIdentityDemo` claim with `subdomain: ci-demo`. |

Deployed via the `cluster-identity-demo` ArgoCD Application (see
`apps/cluster-identity-demo-app.yaml`), which points at this directory in the
nidavellir repo.

## Validating

After ArgoCD syncs:

```bash
# Claim should reach Ready=True / Synced=True
kubectl get clusteridentitydemo -n demo-cluster-identity

# Computed hostname is on the rendered HTTPRoute
kubectl get httproute -n demo-cluster-identity ci-demo \
  -o jsonpath='{.spec.hostnames[0]}'

# cert-manager issues via HTTP-01 through the Traefik Gateway
kubectl get certificate -n demo-cluster-identity ci-demo-tls

# End-to-end (after the cert reaches Ready=True)
curl -sS https://ci-demo.cmdbee.org   # GKE
```

The `letsencrypt-gateway-staging` issuer produces certs that aren't trusted
by browsers by default — use it to validate the ACME pipeline without burning
production rate limits. Switch the claim's `issuer` to `letsencrypt-gateway`
once you've confirmed staging works.

## Why a Composition for a demo?

Because the *point* is to exercise the cluster-identity composition pattern.
The existing `demos/whoami/` directory is plain Kubernetes manifests with a
hardcoded `test.cmdbee.org` — fine for a one-shot manual validation but
doesn't tell you anything about how Crossplane consumes EnvironmentConfig
values. This demo does, and stays env-agnostic in the process.
