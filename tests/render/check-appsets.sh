#!/usr/bin/env bash
# Shape check for the apps/ directory after the Phase 3a conversion: two
# ApplicationSets with guarded identity lookups and the two safety settings, no
# seed URL, no MACHINE placeholder, the vendor pin in the vendor org, and the
# finalizer gone from the two converted apps. Run from the nidavellir root.
set -euo pipefail
fail=0
check() { if grep -Fq -- "$3" "$2"; then found=yes; else found=no; fi; [[ "$found" == "$1" ]] || { echo "FAIL: expected $3 present=$1" >&2; fail=1; }; }
tmp=$(mktemp "${TMPDIR:-/tmp}/apps.XXXXXX"); trap 'rm -f "$tmp"' EXIT
kubectl kustomize apps > "$tmp"
check yes "$tmp" 'kind: ApplicationSet'
check no  "$tmp" 'gitea-http.gitea.svc.cluster.local'
check no  "$tmp" 'nordri-admin'
check no  "$tmp" 'MACHINE'
check no  "$tmp" 'teralivekubernetes'
check yes "$tmp" 'http://git.gitops.svc.cluster.local:3000/siliconsaga-vendor/keycloak-k8s-resources.git'
check yes "$tmp" 'applicationsSync: create-update'
check yes "$tmp" 'preserveResourcesOnDeletion: true'
check yes "$tmp" 'nordri.siliconsaga.org/tailnet: "true"'
check yes "$tmp" 'fail "identity: environment label missing'
check yes "$tmp" 'fail "identity: tailnet-node annotation missing'
check yes "$tmp" 'fail "identity: gcp-project annotation missing'
check yes "$tmp" 'fail "cluster Secret lacks label nordri.siliconsaga.org/environment"'
for f in apps/vegvisir-app.yaml apps/tailscale-operator-app.yaml; do
    grep -q 'resources-finalizer' "$f" && { echo "FAIL: $f still carries the finalizer" >&2; fail=1; }
done
grep -q 'teralivekubernetes' vegvisir/manifests/base/cert-manager-app.yaml && { echo "FAIL: project still in base" >&2; fail=1; }
[[ $fail -eq 0 ]] && echo "appset shape checks: PASS"; exit $fail
