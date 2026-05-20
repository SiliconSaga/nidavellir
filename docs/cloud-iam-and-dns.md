# Cloud IAM and DNS

The GCP-side setup that makes the platform's wildcard certificate possible: a Workload Identity binding (no service-account keys stored anywhere) and a Cloud DNS managed zone for the test domain.

## Test domain

`cmdbee.org` is the platform's test domain. Domain **registration** is at NameCheap; DNS **resolution** is on Google Cloud DNS (managed zone `cmdbee-org` in project `teralivekubernetes`). Co-locating DNS resolution in the same GCP project as the cluster is what makes the keyless Workload Identity path below possible.

Apex and wildcard `A` records point at the Traefik LoadBalancer.

## Workload Identity — no keys

Wildcard certificates require DNS-01 (HTTP-01 cannot satisfy a wildcard). cert-manager must write a temporary `_acme-challenge.cmdbee.org` TXT record into the Cloud DNS zone to satisfy the ACME challenge. It authenticates via **Workload Identity** — no service-account key is stored anywhere:

- GCP SA `cert-manager-dns01@teralivekubernetes.iam.gserviceaccount.com` holds `roles/dns.admin`.
- The cert-manager controller's Kubernetes SA (`cert-manager/cert-manager`) is annotated `iam.gke.io/gcp-service-account: <that SA>` (set in `cert-manager-app.yaml` Helm values), and a `roles/iam.workloadIdentityUser` binding lets it impersonate the GCP SA.
- The ClusterIssuer's `cloudDNS` solver has no `serviceAccountSecretRef` — it uses the ambient WI credentials.

## Reproducing the GCP-side setup

One-time, idempotent. Requires the GKE cluster to have Workload Identity enabled (`workloadPool` set; `default-pool` running `GKE_METADATA`).

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

This is out-of-GitOps (it's cloud IAM, not cluster state) — the same category as the Gitea admin credentials created by `nordri/bootstrap.sh`. A fresh cluster needs these three commands run once before the wildcard cert can issue.

## Related

- [TLS and Certificates](tls-and-certificates.md) — what this IAM and DNS setup is in service of.
