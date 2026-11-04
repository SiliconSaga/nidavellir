#!/usr/bin/env bash
# Offline render check for the ntfy composition's replica count. Requires Docker
# and the crossplane CLI (realm docs/dev-setup.md). Run from the nidavellir repo
# root:
#   bash tests/render/check-ntfy.sh
#
# ⚠ WHY THIS FILE EXISTS. ntfy rendered 1 replica on gke and 0 everywhere else,
# on the reasoning that homelab had no external exposure so a running ntfy had
# no audience. But heimdall's Alertmanager posts to
# ntfy.ntfy.svc.cluster.local in EVERY realm, so 0 replicas meant a Service with
# no endpoints and every homelab alert failing to deliver — including the
# AlertmanagerClusterFailedToSendAlerts that reports it, which routes to the very
# receiver it is complaining about. Nothing caught that for the life of the
# cluster, so the replica count is now asserted rather than assumed.
set -euo pipefail

command -v crossplane >/dev/null || { echo "crossplane CLI not on PATH — install from https://docs.crossplane.io/latest/cli/" >&2; exit 1; }

render() { # $1=env $2=xr-file
    crossplane render "$2" ntfy/composition.yaml \
        tests/render/functions.yaml --extra-resources "tests/render/cluster-identity-$1.yaml"
}

fail=0
check() { # $1=label $2=haystack-file $3=want(yes|no) $4=needle
    if grep -Fq -- "$4" "$2"; then found=yes; else found=no; fi
    if [[ "$found" != "$3" ]]; then
        echo "FAIL [$1]: expected $4 present=$3, got present=$found" >&2
        fail=1
    fi
}

tmp_home=$(mktemp "${TMPDIR:-/tmp}/ntfy-home.XXXXXX") tmp_gke=$(mktemp "${TMPDIR:-/tmp}/ntfy-gke.XXXXXX") tmp_off=$(mktemp "${TMPDIR:-/tmp}/ntfy-off.XXXXXX")
trap 'rm -f "$tmp_home" "$tmp_gke" "$tmp_off"' EXIT
render homelab tests/render/ntfy-xr.yaml     > "$tmp_home"
render gke     tests/render/ntfy-xr.yaml     > "$tmp_gke"
render homelab tests/render/ntfy-xr-off.yaml > "$tmp_off"

# THE REGRESSION THIS GUARDS: homelab must run a replica, so the Service that
# Alertmanager posts to actually has an endpoint.
check homelab "$tmp_home" yes 'replicas: 1'
check homelab "$tmp_home" no  'replicas: 0'

# gke is unchanged by this fix and must stay at 1.
check gke "$tmp_gke" yes 'replicas: 1'
check gke "$tmp_gke" no  'replicas: 0'

# The escape hatch survives: a realm can still decline ntfy on purpose.
check off "$tmp_off" yes 'replicas: 0'
check off "$tmp_off" no  'replicas: 1'

# The Service Alertmanager targets, and the PVC ntfy retains messages in, render
# in every realm regardless of replica count — delivery is what changed, not the
# shape of the resources.
for f in "$tmp_home" "$tmp_gke" "$tmp_off"; do
    check shape "$f" yes 'name: ntfy'
    check shape "$f" yes 'namespace: ntfy'
done

# A literal placeholder must never reach a render: nordri's
# patch_nidavellir_tree stamps ntfy-MACHINE per box at hydration, and a survivor
# would mean two clusters fighting over one MagicDNS name.
for f in "$tmp_home" "$tmp_gke" "$tmp_off"; do
    check placeholder "$f" no 'ntfy-MACHINE'
done

# The Tailscale device annotation stays gke-only, so homelab does not advertise
# a tailnet name it has no operator to claim.
check homelab "$tmp_home" no  'tailscale.com/hostname'
check gke     "$tmp_gke"  yes 'tailscale.com/hostname: ntfy-loki'

[[ $fail -eq 0 ]] && echo "ntfy render checks: PASS"
exit $fail
