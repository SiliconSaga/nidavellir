# Traefik Version Pins

The Traefik chart in `nordri` is pinned to the **3.6.x** line (chart 38.x) for one specific reason: **Traefik 3.7.x regressed the Gateway provider's certificate loading entirely.** On 3.7.1, even a single valid, same-namespace `certificateRef` is never loaded into the TLS store — every host serves Traefik's self-signed default certificate.

On 3.6.5, the wildcard certificate serves correctly across all hosts. Stay on 3.6.x.

Do not bump to chart 40.x / Traefik 3.7.x without re-testing TLS end to end.

## Related background

This is a *separate* defect from the Gateway API multi-`certificateRef` limitation that originally motivated the wildcard cert design — see [TLS and Certificates](tls-and-certificates.md) for that story. The version pin protects against a different bug at a different layer.

## References

- [Traefik #11972](https://github.com/traefik/traefik/issues/11972) — Gateway API SNI iteration across multiple `certificateRefs` (open, unfixed). The bug that motivates the wildcard design.
- [yggdrasil#65](https://github.com/SiliconSaga/yggdrasil/issues/65) — the long-term three-tier (public / LAN / mesh) access architecture this fits into.

## What to re-test before bumping Traefik

1. `kubectl kuttl test --config kuttl-test.yaml` — base platform tests.
2. `WHOAMI_DOMAIN=test.cmdbee.org kubectl kuttl test --config kuttl-test-e2e.yaml` — end-to-end TLS.
3. Manually verify a non-default host serves the Let's Encrypt cert, not Traefik's default:

```bash
echo | openssl s_client -servername gitea.cmdbee.org \
  -connect gitea.cmdbee.org:443 2>/dev/null | openssl x509 -noout -subject -issuer
```

Both kuttl suites must pass and the manual check must show the issuer as Let's Encrypt.
