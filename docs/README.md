# Nidavellir Docs

Operational and design documentation for the Nidavellir platform layer (Vegvísir, Mimir, Keycloak, Heimdall, Vörðu, OpenBAO). For Nidavellir's purpose and tech-stack overview, see the [repo README](../README.md).

## Topics

| File | Covers |
|---|---|
| [TLS and Certificates](tls-and-certificates.md) | The platform's wildcard-cert HTTPS termination — design, manifests, verification, renewal, cert-manager / Gateway API gotchas |
| [Traefik Version Pins](traefik-version-pins.md) | Why Traefik stays on 3.6.x — what 3.7.x broke, what to re-test before bumping |
| [Cloud IAM and DNS](cloud-iam-and-dns.md) | Workload Identity + Cloud DNS — the GCP-side setup that makes the wildcard cert possible, plus the test domain (`cmdbee.org`) |
| [Secrets Management](secrets-management.md) | OpenBao + External Secrets Operator — the sealing concept from zero, how to put/consume values, unseal + init runbooks, custody posture (test vs live) |
| [Testing](testing.md) | Running the platform and end-to-end kuttl suites |
| [Platform Gitea](platform-gitea.md) | Day-2 plan for moving from the bootstrap Seed Gitea to a proper platform Gitea (Mimir-backed, TLS, durable storage) |

## Where to start

New to the platform's HTTPS story? Read [TLS and Certificates](tls-and-certificates.md) first; [Traefik Version Pins](traefik-version-pins.md) and [Cloud IAM and DNS](cloud-iam-and-dns.md) are its companions covering specific corners.

New to secrets (or wondering why `openbao-0` shows `0/1` after a restart)? [Secrets Management](secrets-management.md) explains sealing from zero and carries the runbooks.
