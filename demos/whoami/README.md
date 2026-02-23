# whoami demo

Validation app for the Vegvísir routing + cert-manager pipeline.

## What it tests

- HTTPRoute attachment to `traefik-gateway` (Gateway is Programmed)
- cert-manager HTTP-01 challenge via `letsencrypt-gateway-staging`
- Staging cert issuance end-to-end (DNS → LB → challenge → cert)

## How to deploy

1. DNS must be pointing at the Traefik LB IP (`kubectl get svc traefik -n kube-system`)
2. Edit `whoami.yaml` and replace domain name if needed
3. Apply directly or wire up as a temporary ArgoCD Application:

```bash
kubectl apply -f whoami.yaml
```

## What to check after deploying

```bash
# Certificate issued?
kubectl get certificate whoami-cert -n demo-whoami

# Secret created by cert-manager?
kubectl get secret whoami-tls -n demo-whoami

# Route reachable?
curl http://test.cmdbee.org/
```

The staging cert will not be trusted by browsers, but `curl -k` or checking
`kubectl describe certificate` should show it as Ready.

## Cleanup

```bash
kubectl delete namespace demo-whoami
```
