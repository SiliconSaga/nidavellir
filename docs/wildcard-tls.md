# Wildcard TLS — Vegvísir

How the platform terminates HTTPS for `*.cmdbee.org`, and why it's built this way.

## TL;DR

A single wildcard certificate (`*.cmdbee.org` + apex) is issued by cert-manager
via a DNS-01 ACME challenge through Google Cloud DNS, stored as one Secret in
`kube-system`, and served by the Traefik Gateway's `websecure` listener as its
**only** `certificateRef`. Every host — current and future — is covered at once.
New apps get working HTTPS with zero per-app certificate action.

## Why not per-host certificates

The earlier design gave each app its own cert-manager `Certificate` +
`ReferenceGrant`, with the Traefik Gateway listener carrying one `certificateRef`
per host. **This does not work.** Traefik's Gateway API provider does not
reliably SNI-iterate across multiple `certificateRefs` on a single listener — it
uses the first and serves the self-signed default cert for every other host
([Traefik #11972](https://github.com/traefik/traefik/issues/11972), open and
unfixed; reproduced here on both Traefik 3.6.5 and 3.7.1). The Gateway API spec
only *mandates* single-`certificateRef` support per listener; multiple is
"implementation-specific," and Traefik's implementation is the broken one.

A wildcard cert sidesteps this entirely: with exactly **one** cert on the
listener, Traefik never reaches its broken cert-selection path. See
[yggdrasil#65](https://github.com/SiliconSaga/yggdrasil/issues/65) for the full
investigation and the broader TLS/DNS/access-tier direction.

## Components

| File | Role |
|---|---|
| `vegvisir/manifests/letsencrypt-dns01.yaml` | ClusterIssuer — ACME prod, DNS-01 solver via Cloud DNS |
| `vegvisir/manifests/wildcard-cert.yaml` | `Certificate` for `*.cmdbee.org` + `cmdbee.org` → Secret `wildcard-cmdbee-tls` in `kube-system` |
| `vegvisir/manifests/traefik-gateway.yaml` | `websecure` listener references `wildcard-cmdbee-tls` as its single `certificateRef` |
| `vegvisir/manifests/cert-manager-app.yaml` | cert-manager Helm app; its SA is annotated for Workload Identity |

## Authentication — Workload Identity, no keys

Wildcard certs require DNS-01 (HTTP-01 cannot satisfy a wildcard). cert-manager
must write a temporary `_acme-challenge.cmdbee.org` TXT record into the Cloud DNS
zone. It authenticates via **Workload Identity** — no service-account key is
stored anywhere:

- GCP SA `cert-manager-dns01@teralivekubernetes.iam.gserviceaccount.com` holds
  `roles/dns.admin`.
- The cert-manager controller's Kubernetes SA (`cert-manager/cert-manager`) is
  annotated `iam.gke.io/gcp-service-account: <that SA>` (set in
  `cert-manager-app.yaml` Helm values), and a `roles/iam.workloadIdentityUser`
  binding lets it impersonate the GCP SA.
- The ClusterIssuer's `cloudDNS` solver has no `serviceAccountSecretRef` — it
  uses the ambient WI credentials.

### Reproducing the GCP-side setup

One-time, idempotent. Requires the GKE cluster to have Workload Identity enabled
(`workloadPool` set; `default-pool` running `GKE_METADATA`).

```bash
PROJECT=teralivekubernetes
SA=cert-manager-dns01
SA_EMAIL="${SA}@${PROJECT}.iam.gserviceaccount.com"

# 1. Service account
gcloud iam service-accounts create "$SA" --project "$PROJECT" \
  --display-name "cert-manager DNS-01 solver (Cloud DNS)"

# 2. DNS admin on the project
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${SA_EMAIL}" --role roles/dns.admin --condition=None

# 3. Workload Identity binding (KSA -> GSA impersonation)
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT}.svc.id.goog[cert-manager/cert-manager]"
```

This is out-of-GitOps (it's cloud IAM, not cluster state) — the same category as
the Gitea admin credentials created by `nordri/bootstrap.sh`. A fresh cluster
needs these three commands run once before the wildcard cert can issue.

## Verifying

```bash
# Certificate issued?
kubectl -n kube-system get certificate wildcard-cmdbee
# Expect READY=True within ~2-5 min of first sync.

# Served cert for any host (should be Let's Encrypt, not TRAEFIK DEFAULT CERT):
echo | openssl s_client -servername gitea.cmdbee.org \
  -connect gitea.cmdbee.org:443 2>/dev/null | openssl x509 -noout -subject -issuer
```

## DNS

`cmdbee.org` is hosted on Google Cloud DNS (managed zone `cmdbee-org`, project
`teralivekubernetes`) — apex + wildcard `A` records point at the Traefik
LoadBalancer. Co-locating DNS in the same GCP project as the cluster is what
makes the keyless Workload Identity path possible.

## Renewal

cert-manager auto-renews the wildcard well before its 90-day expiry, re-running
the DNS-01 challenge each time. No operator action required.

## Relationship to other docs

- [`platform-gitea.md`](platform-gitea.md) — the Forgejo day-2 plan; its earlier
  per-host cert assumptions are superseded by this wildcard approach.
- [yggdrasil#65](https://github.com/SiliconSaga/yggdrasil/issues/65) — the
  long-term three-tier (public / LAN / mesh) access architecture this fits into.
