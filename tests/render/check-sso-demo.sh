#!/usr/bin/env bash
# Offline render check for the SSO demo composition: renders both
# environment branches with the crossplane CLI (Docker required; install
# per realm docs/dev-setup.md) and asserts the env seams landed on the
# right side. Run from the nidavellir repo root:
#   bash tests/render/check-sso-demo.sh
set -euo pipefail

command -v crossplane >/dev/null || { echo "crossplane CLI not on PATH — see realm docs/dev-setup.md" >&2; exit 1; }

render() {
    crossplane render tests/render/sso-demo-xr.yaml sso-demo/composition.yaml \
        tests/render/functions.yaml --extra-resources "tests/render/cluster-identity-$1.yaml"
}

fail=0
check() { # $1=label $2=haystack-file $3=want(yes|no) $4=needle
    if grep -q -- "$4" "$2"; then found=yes; else found=no; fi
    if [[ "$found" != "$3" ]]; then
        echo "FAIL [$1]: expected $4 present=$3, got present=$found" >&2
        fail=1
    fi
}

tmp_home=$(mktemp) tmp_gke=$(mktemp)
trap 'rm -f "$tmp_home" "$tmp_gke"' EXIT
render homelab > "$tmp_home"
render gke     > "$tmp_gke"

# The realm-import redirectUris list carries BOTH hostnames in BOTH renders
# by design (it's static, not env-branched), so we assert on the env-branched
# oauth2-proxy FLAGS, never on the redirectUris.
#
# homelab: split-horizon lab config + localhost routes; the gke-only secure
# flags must be absent.
check homelab "$tmp_home" yes "sso-demo.localhost"
check homelab "$tmp_home" yes "keycloak.localhost"
check homelab "$tmp_home" yes "insecure-oidc-skip-issuer-verification"
check homelab "$tmp_home" yes "cookie-secure=false"
check homelab "$tmp_home" yes "sectionName: web"
check homelab "$tmp_home" no  "redirect-url=https://sso-demo.cmdbee.org"
check homelab "$tmp_home" no  "cookie-secure=true"

# gke: clean discovery, secure cookies, websecure; no lab compromises and no
# homelab-only keycloak.localhost route/hostname leak.
check gke "$tmp_gke" yes "oidc-issuer-url=https://keycloak.cmdbee.org/realms/demo"
check gke "$tmp_gke" yes "redirect-url=https://sso-demo.cmdbee.org/oauth2/callback"
check gke "$tmp_gke" yes "cookie-secure=true"
check gke "$tmp_gke" yes "sectionName: websecure"
check gke "$tmp_gke" no  "insecure-oidc-skip-issuer-verification"
check gke "$tmp_gke" no  "skip-oidc-discovery"
check gke "$tmp_gke" no  "keycloak.localhost"

# both placeholders must survive go-templating as literals in BOTH renders
check homelab "$tmp_home" yes '${SSO_DEMO_CLIENT_SECRET}'
check homelab "$tmp_home" yes '${SSO_DEMO_USER_PASSWORD}'
check gke     "$tmp_gke"  yes '${SSO_DEMO_CLIENT_SECRET}'
check gke     "$tmp_gke"  yes '${SSO_DEMO_USER_PASSWORD}'

if [[ "$fail" == "0" ]]; then
    echo "OK: both env renders carry the right seams"
else
    exit 1
fi
