# Demos

Self-contained demonstration apps that exercise platform capabilities end to end on a live cluster. Each is disposable and carries its own README with deploy / verify / retire steps.

**None of these are stack members.** They ship no ArgoCD Application and do not auto-deploy. Apply a demo's manifests directly when you want it (`kubectl apply -f demos/<name>`), then delete them when done. (If a demo ever needs to stand permanently, author an Application for it under `apps/` and add it to `apps/kustomization.yaml` then.)

| Demo | Exercises | Shape |
|---|---|---|
| [`whoami/`](whoami/README.md) | Vegvísir routing + cert-manager HTTP-01 issuance | plain Kubernetes manifests |
| [`cluster-identity/`](cluster-identity/README.md) | the cluster-identity composition pattern (EnvironmentConfig → per-env hostname) | Crossplane composition |
| [`sso/`](sso/README.md) | the full secrets-to-SSO chain (OpenBao → ESO → Keycloak → oauth2-proxy) | Crossplane composition |

These are demonstrations, not platform services.
