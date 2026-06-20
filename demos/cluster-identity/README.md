# Cluster Identity Demo

A minimal Crossplane Composition that exercises the
[cluster-identity pattern](https://github.com/SiliconSaga/nordri/blob/main/docs/cluster-identity.md)
end-to-end on a live cluster: it deploys a `traefik/whoami` echo service
behind an `HTTPRoute`, with the hostname built from
`EnvironmentConfig/cluster-identity` (loaded into the pipeline by
`function-environment-configs`).

It's a substrate smoke test, not a workload — useful when you want to verify
that:

- `function-environment-configs` is healthy and the EnvironmentConfig fields
  flow into a downstream `function-go-templating` step
- The Traefik Gateway accepts a Crossplane-rendered `HTTPRoute`
- Per-environment defaulting actually produces the expected hostname for
  this cluster (`ci-demo.cmdbee.org` on GKE, `ci-demo.homelab.local` on
  homelab)

## How it's wired

| Resource | Purpose |
|----------|---------|
| `xrd.yaml` | `XClusterIdentityDemo` API. Required: `subdomain`. Optional: `domain` (override). |
| `composition.yaml` | Pipeline: `load-cluster-identity` → render `Deployment` + `Service` → render `HTTPRoute` → `auto-ready`. |
| `claim.yaml` | Sample `ClusterIdentityDemo` claim with `subdomain: ci-demo`. |

Deployed via the `cluster-identity-demo` ArgoCD Application (see
`apps/cluster-identity-demo-app.yaml`), which points at this directory in the
nidavellir repo.

## Validating

After ArgoCD syncs:

```bash
# Claim should reach Ready=True / Synced=True
kubectl get clusteridentitydemo -n demo-cluster-identity

# Computed hostname is on the rendered HTTPRoute (and matches cluster-identity)
kubectl get httproute -n demo-cluster-identity ci-demo \
  -o jsonpath='{.spec.hostnames[0]}'

# HTTPS reaches the whoami pod, served by the platform wildcard cert
curl -sS https://ci-demo.cmdbee.org   # GKE
```

### What this validates

- **cluster-identity defaulting**: the rendered HTTPRoute's hostname comes
  from `EnvironmentConfig/cluster-identity` via the composition pipeline.
- **HTTPRoute attachment**: the route binds to both the `web` (HTTP) and
  `websecure` (HTTPS) listeners on `traefik-gateway`.
- **TLS**: on GKE, `https://ci-demo.cmdbee.org` is served browser-trusted by
  the platform wildcard cert (`*.cmdbee.org`) — no per-host `Certificate`.

### TLS notes

This demo renders no `Certificate` of its own. TLS for `*.cmdbee.org` is the
platform wildcard served from the shared Gateway (see
`docs/tls-and-certificates.md`), so any `<host>.cmdbee.org` HTTPRoute gets
HTTPS for free. On homelab there is no wildcard cert — the Gateway serves its
self-signed default, which is fine for a smoke test whose point is the
cluster-identity-derived hostname, not TLS.

## Why a Composition for a demo?

Because the *point* is to exercise the cluster-identity composition pattern.
The existing `demos/whoami/` directory is plain Kubernetes manifests with a
hardcoded `test.cmdbee.org` — fine for a one-shot manual validation but
doesn't tell you anything about how Crossplane consumes EnvironmentConfig
values. This demo does, and stays env-agnostic in the process.
