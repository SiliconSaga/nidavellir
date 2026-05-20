# TLS and Certificates

How the platform terminates HTTPS for `*.cmdbee.org`, and why it's built this way.

## TL;DR

A single wildcard certificate (`*.cmdbee.org` + apex) is issued by cert-manager via a DNS-01 ACME challenge through Google Cloud DNS, stored as one Secret in `kube-system`, and served by the Traefik Gateway's `websecure` listener as its **only** `certificateRef`. Every host — current and future — is covered at once. New apps get working HTTPS with zero per-app certificate action.

## Why not per-host certificates

The earlier design gave each app its own cert-manager `Certificate` + `ReferenceGrant`, with the Traefik Gateway listener carrying one `certificateRef` per host. **This does not work.** Traefik's Gateway API provider does not reliably SNI-iterate across multiple `certificateRefs` on a single listener — it uses the first and serves the self-signed default cert for every other host ([Traefik #11972](https://github.com/traefik/traefik/issues/11972), open and unfixed). The Gateway API spec only *mandates* single-`certificateRef` support per listener; multiple is "implementation-specific," and Traefik's implementation is the broken one.

A wildcard cert sidesteps this entirely: with exactly **one** cert on the listener, Traefik never reaches its broken cert-selection path.

A *separate* defect required pinning Traefik to 3.6.x — see [Traefik Version Pins](traefik-version-pins.md).

## Components

| File | Role |
|---|---|
| `vegvisir/manifests/letsencrypt-dns01.yaml` | ClusterIssuer — ACME prod, DNS-01 solver via Cloud DNS |
| `vegvisir/manifests/wildcard-cert.yaml` | `Certificate` for `*.cmdbee.org` + `cmdbee.org` → Secret `wildcard-cmdbee-tls` in `kube-system` |
| `vegvisir/manifests/traefik-gateway.yaml` | `websecure` listener references `wildcard-cmdbee-tls` as its single `certificateRef` |
| `vegvisir/manifests/cert-manager-app.yaml` | cert-manager Helm app; its SA is annotated for Workload Identity |

The authentication, Cloud DNS, and IAM details that make this work — including the gcloud reproduction commands for a fresh cluster — live in [Cloud IAM and DNS](cloud-iam-and-dns.md).

## Verifying

```bash
# Certificate issued?
kubectl -n kube-system get certificate wildcard-cmdbee
# Expect READY=True within ~2-5 min of first sync.

# Served cert for any host (should be Let's Encrypt, not TRAEFIK DEFAULT CERT):
echo | openssl s_client -servername gitea.cmdbee.org \
  -connect gitea.cmdbee.org:443 2>/dev/null | openssl x509 -noout -subject -issuer
```

## Renewal

cert-manager auto-renews the wildcard well before its 90-day expiry, re-running the DNS-01 challenge each time. No operator action required.

## Gotchas

- **cert-manager Certificate conditions** differ by state. While issuing: `[Ready=False, Issuing=True]`. After issued: `[Ready=True]` only — `Issuing` disappears entirely. Assertions that look for `Issuing=False` after issuance will fail.
- **Gateway API condition assertions** must include ALL conditions present (e.g. both `Programmed` and `Accepted`), not just the one being checked. Partial assertions match in unexpected ways.
- **cert-manager Gateway API integration** is enabled via the `ControllerConfiguration` resource, not via `--feature-gates` flags. The `ControllerConfiguration` path is the supported one going forward.

## Related

- [Platform Gitea](platform-gitea.md) — the Forgejo day-2 plan; its earlier per-host cert assumptions are superseded by this wildcard approach.
- [yggdrasil#65](https://github.com/SiliconSaga/yggdrasil/issues/65) — the long-term three-tier (public / LAN / mesh) access architecture this fits into.
