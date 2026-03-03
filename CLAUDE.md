# Nidavellir — Platform Layer (Tier 2)

Nidavellir is the developer platform app-of-apps: Vegvísir (Gateway + TLS), Mimir
(data services), Keycloak, Heimdall, Vörðu, OpenBAO. It also bootstraps Tier 3 (Demicracy).
ArgoCD (in Nordri) deploys Nidavellir via `platform/argocd/nidavellir-apps.yaml`.

**Full agent context:** [`yggdrasil/CLAUDE.md`](../yggdrasil/CLAUDE.md) and
[`yggdrasil/docs/ecosystem-architecture.md`](../yggdrasil/docs/ecosystem-architecture.md)

---

## Key Commands

### Run platform tests (fast, no DNS needed)
```bash
kubectl kuttl test --config kuttl-test.yaml
# Tests: vegvisir, cert-manager, ClusterIssuers, default cert
```

### Run e2e tests (requires live DNS for cmdbee.org)
```bash
WHOAMI_DOMAIN=test.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
# Tests: whoami cert issuance via ACME + HTTP routing
```

---

## Key Gotchas

- **cert-manager Certificate conditions** differ by state:
  - While issuing: `[Ready=False, Issuing=True]`
  - After issued: `[Ready=True]` only — `Issuing` disappears entirely
- **Gateway API conditions**: assertions must include ALL conditions (e.g. both `Programmed`
  and `Accepted`), not just the one you're checking.
- **cert-manager Gateway API**: enable via `ControllerConfiguration`, not `--feature-gates`.
  See `MEMORY.md` for the exact Helm values block.
- **Heimdall**: `heimdall-app.yaml` not yet created. See `heimdall/design.md` for the
  planned ArgoCD Application (sync wave 10, path `heimdall/crossplane/`).
- **Test domain**: `cmdbee.org` (NameCheap, test-only). All DNS records can be replaced.
