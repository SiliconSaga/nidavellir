# Demos

Self-contained demonstration apps that exercise platform capabilities end to
end on a live cluster. Each is disposable, carries its own README with
deploy / verify / retire steps, and (except `whoami`, applied directly) is
deployed via its own ArgoCD Application in `apps/`.

| Demo | Exercises | Shape |
|---|---|---|
| [`whoami/`](whoami/README.md) | Vegvísir routing + cert-manager HTTP-01 issuance | plain Kubernetes manifests |
| [`cluster-identity/`](cluster-identity/README.md) | the cluster-identity composition pattern (EnvironmentConfig → per-env hostname) | Crossplane composition |
| [`sso/`](sso/README.md) | the full secrets-to-SSO chain (OpenBao → ESO → Keycloak → oauth2-proxy) | Crossplane composition |

These are demonstrations, not platform services. Retire any of them by removing
its app from `apps/kustomization.yaml` (or, for `whoami`, deleting its
namespace).
