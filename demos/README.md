# Demos

Self-contained demonstration apps that exercise platform capabilities end to end on a live cluster. Each is disposable and carries its own README with deploy / verify / retire steps.

**None of these auto-deploy.** They are ad hoc: apply a demo's manifests directly when you want it (`kubectl apply -f demos/<name>`), then delete them when done. Do not apply the `apps/<name>-app.yaml` files by hand — the app-of-apps prunes+selfHeals, so an Application not listed in `apps/kustomization.yaml` gets pruned again on the next sync. The app files are retained only so a demo *could* be re-added to the index if it ever needs to stand permanently.

| Demo | Exercises | Shape |
|---|---|---|
| [`whoami/`](whoami/README.md) | Vegvísir routing + cert-manager HTTP-01 issuance | plain Kubernetes manifests |
| [`cluster-identity/`](cluster-identity/README.md) | the cluster-identity composition pattern (EnvironmentConfig → per-env hostname) | Crossplane composition |
| [`sso/`](sso/README.md) | the full secrets-to-SSO chain (OpenBao → ESO → Keycloak → oauth2-proxy) | Crossplane composition |

These are demonstrations, not platform services.
