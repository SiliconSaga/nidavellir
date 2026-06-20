# SSO Demo — OpenBao + ESO + Keycloak, end to end

One `SSODemo` claim that exercises the full secrets-to-SSO substrate in a single observable act: secrets born in **OpenBao**, delivered by **ESO**, consumed simultaneously by **Keycloak** (the `demo` realm's client secret and demo-user password arrive via realm-import placeholders) and by a real OIDC app (**oauth2-proxy** fronting **whoami**). If you can log in, the whole chain works.

Design + decision trail: realm-siliconsaga `docs/plans/2026-06-11-sso-demo-design.md`.

## Prerequisites

- **The platform substrate is up.** This demo consumes standing platform services — OpenBao, ESO, the Keycloak operator + instance — which *are* auto-deployed. They must be healthy before the demo can converge.
- **OpenBao is unsealed.** A restarted `openbao-0` comes back sealed; unseal it first (`docs/secrets-management.md` → "The pod restarted and shows 0/1"). While sealed, ESO cannot read and the demo Secrets never materialize.

## Deploying it (ad hoc — not auto-deployed)

This demo is **not** a stack member — it ships no ArgoCD Application and does not auto-deploy. Like `demos/whoami`, apply its manifests directly when you want it:

```bash
kubectl apply -f demos/sso/    # xrd + composition + claim
# If Crossplane reports the claim before the XSSODemo XRD has established, re-run once.
kubectl get pods -n sso-demo   # oauth2-proxy + whoami come up once secrets converge
```

Retire it with `kubectl delete -f demos/sso/` (and see "Retiring the demo" below for the Retain'd Secrets). To make it a permanent stack member instead, author an Application under `apps/` and list it in `apps/kustomization.yaml`.

## Seed it (once per cluster)

The demo's three values live at `secret/sso-demo` in OpenBao and never touch git. Until they exist, the ExternalSecrets and the realm import simply wait — that's the designed resting state, not a failure. Seed with the root token (see `docs/secrets-management.md` for token custody):

```bash
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao kv put secret/sso-demo \
  client-secret=<random-string> cookie-secret=<32-byte-base64> demo-user-password=<pick-one>
```

`cookie-secret` must be 16, 24, or 32 bytes base64-encoded (e.g. from `head -c 32 /dev/urandom | base64`). The kuttl acceptance test seeds random values automatically if the path is empty — it never overwrites existing ones.

## Try it in a browser

Retrieve the demo password from OpenBao (custody UX is part of the demo):

```bash
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao kv get -field=demo-user-password secret/sso-demo
```

| Environment | URL | Notes |
|---|---|---|
| homelab | `http://sso-demo.localhost` | Works in any modern browser on the cluster host — `*.localhost` auto-resolves to 127.0.0.1 and rides the gateway's HTTP listener (the `gitea.localhost` pattern). Keycloak itself is at `http://keycloak.localhost`. |
| GKE | `https://sso-demo.cmdbee.org` | Real TLS via the platform wildcard. Keycloak at `https://keycloak.cmdbee.org`. |

You'll be bounced straight to the Keycloak `demo` realm's login page. Sign in as **`demo`** with the password you just read. whoami then shows your request — look for the `X-Forwarded-User: demo` and `X-Forwarded-Email: demo@example.com` headers oauth2-proxy injected: that's Keycloak's word for who you are, delivered through the whole substrate.

Log out by clearing the `_oauth2_proxy` cookie (or browse `/oauth2/sign_out`).

## How the homelab browser flow works (split-horizon)

On homelab the browser and the cluster see Keycloak through different addresses, so oauth2-proxy runs the classic lab config: the browser-facing login URL points at `keycloak.localhost`, while token redemption and JWKS fetch go through `keycloak-service.keycloak.svc` in-cluster, with issuer verification relaxed and plain-HTTP cookies. Those compromises exist ONLY in the composition's homelab branch — GKE uses clean discovery against the external issuer with secure cookies. See `composition.yaml`'s step comments.

## Automated acceptance

`tests/e2e/sso-demo/` (run via `./test.ps1 -Config kuttl-test-e2e.yaml --test sso-demo` on Windows): seeds OpenBao if empty, asserts the Secrets materialize in both namespaces, requests a real password-grant token from the `demo` realm using the OpenBao-derived client secret, and asserts oauth2-proxy's `/oauth2/start` redirects into the demo realm's auth endpoint. Browserless, runs identically on both environments.

The suite asserts on the **standing** demo (it does not deploy the demo itself), so **apply `demos/sso/` first** (see "Deploying it" above) and make sure OpenBao is unsealed before running it.

## Retiring the demo

`kubectl delete -f demos/sso/` removes the claim and everything it composed. Then, if you want the seeded values gone too:

```bash
ROOT_TOKEN=$(kubectl get secret openbao-init -n openbao -o jsonpath='{.data.root_token}' | base64 -d)
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao kv metadata delete secret/sso-demo
```

Note: the two ExternalSecrets use `deletionPolicy: Retain`, so the **materialized** Kubernetes Secrets (`sso-demo-realm-secrets` in `keycloak`, `sso-demo-oauth2-proxy` in `sso-demo`) survive the prune. Delete them by hand if you want a fully clean teardown:

```bash
kubectl delete secret sso-demo-realm-secrets -n keycloak --ignore-not-found
kubectl delete secret sso-demo-oauth2-proxy -n sso-demo --ignore-not-found
```
