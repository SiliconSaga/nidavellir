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

# durable with the configure Job Ready: the puller appears, carrying the source ref; the Job knows the vendor org.
render cluster-identity-homelab-durable.yaml tests/render/forgejo-xr.yaml tests/render/forgejo-observed-configured.yaml > "$tmp/puller"
check puller "$tmp/puller" yes 'kind: CronJob'
# (render output is YAML re-serialised, so scalars come back unquoted)
check puller "$tmp/puller" yes 'name: SOURCE_REF'
check puller "$tmp/puller" yes 'value: main'
check puller "$tmp/puller" yes 'name: VENDOR_ORG'
check puller "$tmp/puller" yes 'value: siliconsaga-vendor'

# role: test renders no puller; the configure Job carries the role.
render cluster-identity-homelab-test-durable.yaml tests/render/forgejo-xr.yaml tests/render/forgejo-observed-configured.yaml > "$tmp/testrole"
check test-role "$tmp/testrole" no  'kind: CronJob'
check test-role "$tmp/testrole" yes 'name: ROLE'
check test-role "$tmp/testrole" yes 'value: test'

# a claim with one org only fails the render, naming the rule.
cat > "$tmp/xr-one-org.yaml" <<'EOF'
apiVersion: nidavellir.siliconsaga.org/v1alpha1
kind: XForgejo
metadata:
  name: forgejo
spec:
  parameters:
    orgs:
      - {name: siliconsaga, class: canonical}
EOF
if render cluster-identity-homelab-durable.yaml "$tmp/xr-one-org.yaml" > "$tmp/one-org" 2>&1; then
    echo "FAIL [one-org]: render succeeded" >&2; fail=1
else
    check one-org "$tmp/one-org" yes 'exactly one org of each class'
fi

# two canonical entries (and no vendor) fail the render, naming the class rule.
cat > "$tmp/xr-two-canonical.yaml" <<'EOF'
apiVersion: nidavellir.siliconsaga.org/v1alpha1
kind: XForgejo
metadata:
  name: forgejo
spec:
  parameters:
    orgs:
      - {name: siliconsaga, class: canonical}
      - {name: siliconsaga-extra, class: canonical}
EOF
if render cluster-identity-homelab-durable.yaml "$tmp/xr-two-canonical.yaml" > "$tmp/two-canonical" 2>&1; then
    echo "FAIL [two-canonical]: render succeeded" >&2; fail=1
else
    check two-canonical "$tmp/two-canonical" yes 'exactly one org of each class'
fi

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
bash tests/scripts/forgejo-askpass-test.sh > "$tmp/askpass" || { echo "FAIL [askpass]:" >&2; cat "$tmp/askpass" >&2; fail=1; }

[[ $fail -eq 0 ]] && echo "forgejo render checks: PASS"
exit $fail
