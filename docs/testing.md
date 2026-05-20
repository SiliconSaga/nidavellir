# Testing

Two kuttl test suites are available for nidavellir.

## Platform tests (fast, no DNS needed)

```bash
kubectl kuttl test --config kuttl-test.yaml
```

Covers: vegvisir, cert-manager, ClusterIssuers, default certificate.

## End-to-end tests (require live DNS for cmdbee.org)

```bash
WHOAMI_DOMAIN=test.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml
```

Covers: whoami Gateway attachment + HTTP routing. TLS comes from the platform wildcard certificate (see [TLS and Certificates](tls-and-certificates.md)); the demo has no per-host cert of its own.
