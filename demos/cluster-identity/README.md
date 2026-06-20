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

### Deploying it (ad hoc — not auto-deployed)

This demo is **not** in the app-of-apps index (`apps/kustomization.yaml`), so it
does not auto-deploy. Like `demos/whoami`, apply its manifests directly when you
want it, then delete them when done:

```bash
kubectl apply -f demos/cluster-identity/    # xrd + composition + claim
# ... validate (below) ...
kubectl delete -f demos/cluster-identity/
```

Apply the **manifests**, not `apps/cluster-identity-demo-app.yaml`: the
app-of-apps prunes+selfHeals, so a manually applied Application that isn't in the
index would be pruned again on the next sync. (The app file is kept only so the
demo *could* be re-added to the index if it ever needs to stand permanently.) If
Crossplane reports the claim before the `XClusterIdentityDemo` XRD has
established, re-run the apply once.

## Validating

After the claim reconciles:

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
