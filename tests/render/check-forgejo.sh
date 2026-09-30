#!/usr/bin/env bash
# Offline render check for the Forgejo composition's maturity gate and its
# readiness-driven ordering. Requires Docker and the crossplane CLI. Run from
# the nidavellir repo root: bash tests/render/check-forgejo.sh
set -euo pipefail
command -v crossplane >/dev/null || { echo "crossplane CLI not on PATH" >&2; exit 1; }

render() { # $1=identity-file $2=xr-file [$3=observed-file]
    if [[ -n "${3:-}" ]]; then
        crossplane render "$2" forgejo/composition.yaml tests/render/functions.yaml \
            --extra-resources "tests/render/$1" --observed-resources "$3"
    else
        crossplane render "$2" forgejo/composition.yaml tests/render/functions.yaml \
            --extra-resources "tests/render/$1"
    fi
}
fail=0
check() { # $1=label $2=file $3=want(yes|no) $4=needle
    if grep -Fq -- "$4" "$2"; then found=yes; else found=no; fi
    if [[ "$found" != "$3" ]]; then echo "FAIL [$1]: expected $4 present=$3, got present=$found" >&2; fail=1; fi
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/forgejo-render.XXXXXX"); trap 'rm -rf "$tmp"' EXIT

# bootstrap: the XR alone, nothing composed.
render cluster-identity-homelab.yaml tests/render/forgejo-xr.yaml > "$tmp/bootstrap"
check bootstrap "$tmp/bootstrap" no 'kind: Object'
check bootstrap "$tmp/bootstrap" no 'kind: Release'

# durable, nothing observed yet: the first wave only.
render cluster-identity-homelab-durable.yaml tests/render/forgejo-xr.yaml > "$tmp/durable"
check durable "$tmp/durable" yes 'kind: DataService'
check durable "$tmp/durable" yes 'name: forgejo-init'
check durable "$tmp/durable" yes 'name: forgejo-puller'
check durable "$tmp/durable" yes 'automountServiceAccountToken: false'
check durable "$tmp/durable" yes 'resourceNames:'
check durable "$tmp/durable" yes '- forgejo-puller'
check durable "$tmp/durable" yes 'key: secret/forgejo'
check durable "$tmp/durable" yes 'key: secret/forgejo/admins/cervator'
check durable "$tmp/durable" yes 'name: forgejo-admin-cervator'
check durable "$tmp/durable" yes 'name: forgejo-credentials-'
check durable "$tmp/durable" yes 'celQuery: has(object.status.succeeded) && object.status.succeeded > 0'
check durable "$tmp/durable" yes 'nordri SiliconSaga/nordri'
check durable "$tmp/durable" yes 'keycloak-k8s-resources https://github.com/keycloak/keycloak-k8s-resources.git'
check durable "$tmp/durable" yes 'forgejo.homelab.local'
check durable "$tmp/durable" yes 'image: alpine/k8s:1.36.4'
# Not before the admin Secret and the DataService are Ready:
check durable "$tmp/durable" no  'kind: Release'
check durable "$tmp/durable" no  'name: forgejo-configure-'
check durable "$tmp/durable" no  'kind: CronJob'

# durable with the release observed Ready: the configure Job appears, the puller not yet.
render cluster-identity-homelab-durable.yaml tests/render/forgejo-xr.yaml tests/render/forgejo-observed.yaml > "$tmp/configure"
check configure "$tmp/configure" yes 'name: forgejo-configure-'
check configure "$tmp/configure" yes 'mountPath: /etc/forgejo-admins/cervator'
check configure "$tmp/configure" no  'kind: CronJob'

# invalid maturity fails the render, naming the field.
if render cluster-identity-homelab-bad-maturity.yaml tests/render/forgejo-xr.yaml > "$tmp/bad" 2>&1; then
    echo "FAIL [bad-maturity]: render succeeded" >&2; fail=1
else
    check bad-maturity "$tmp/bad" yes 'maturity "someday" is not one of'
fi

# downgrade with composed resources observed: refused without allowTeardown, empty with it.
if render cluster-identity-homelab.yaml tests/render/forgejo-xr.yaml tests/render/forgejo-observed.yaml > "$tmp/downgrade" 2>&1; then
    echo "FAIL [downgrade]: render succeeded without allowTeardown" >&2; fail=1
else
    check downgrade "$tmp/downgrade" yes 'allowTeardown'
fi
render cluster-identity-homelab.yaml tests/render/forgejo-xr-teardown.yaml tests/render/forgejo-observed.yaml > "$tmp/teardown"
check teardown "$tmp/teardown" no 'kind: Release'
check teardown "$tmp/teardown" no 'kind: Object'

# the scripts ConfigMap builds and carries all four scripts.
kubectl kustomize forgejo > "$tmp/kustomize"
for s in credentials.sh configure.sh puller.sh askpass.sh; do check kustomize "$tmp/kustomize" yes "$s: |"; done
check kustomize "$tmp/kustomize" yes 'name: forgejo-scripts'
for s in forgejo/scripts/*.sh; do bash -n "$s" || { echo "FAIL [syntax]: $s" >&2; fail=1; }; done

[[ $fail -eq 0 ]] && echo "forgejo render checks: PASS"
exit $fail
