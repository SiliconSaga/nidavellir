# Testing

Two kuttl test suites are available for nidavellir.

## Platform tests (fast, no DNS needed)

```bash
kubectl kuttl test --config kuttl-test.yaml
```

Covers: vegvisir, cert-manager, ClusterIssuers, default certificate, OpenBao.

`tests/platform/openbao/01-restart.yaml` asserts a restarted `openbao-0` returns Ready unaided, which is only true once the cluster has been graduated to `seal: auto` and migrated ([Secrets Management](secrets-management.md)). On a cluster still on the Shamir default it fails by design; run the suite with `--test` selection excluding `openbao` there, or graduate the cluster.

## End-to-end tests (require live DNS for cmdbee.org)

```bash
WHOAMI_DOMAIN=test.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
```

Covers: whoami Gateway attachment + HTTP routing. TLS comes from the platform wildcard certificate (see [TLS and Certificates](tls-and-certificates.md)); the demo has no per-host cert of its own.

## Offline render checks (no cluster)

Compositions are rendered with the `crossplane` CLI (install: realm `docs/dev-setup.md`) against the fixtures in `tests/render/`, and a script per composition asserts the environment-specific seams. Run from the repo root before any composition change ships:

```bash
bash tests/render/check-openbao.sh     # seal stanza per environment, and the shamir default
bash tests/render/check-sso-demo.sh    # SSO demo env seams
```

What `crossplane render` proves is that the composition emits the intended `Release` values and `Object` manifests. It does not run Helm, so a chart key the chart ignores still renders green; when a change adds new chart values, also run `helm template <chart> -f <values>` once against the pinned chart version to confirm the key lands where you expect (the OpenBao seal work verified `server.serviceAccount.annotations` and `server.extraSecretEnvironmentVars` this way against openbao 0.28.3).
