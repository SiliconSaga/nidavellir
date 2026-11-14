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

tmp_home=$(mktemp "${TMPDIR:-/tmp}/ntfy-home.XXXXXX") tmp_gke=$(mktemp "${TMPDIR:-/tmp}/ntfy-gke.XXXXXX") tmp_off=$(mktemp "${TMPDIR:-/tmp}/ntfy-off.XXXXXX") tmp_tail=$(mktemp "${TMPDIR:-/tmp}/ntfy-tail.XXXXXX")
trap 'rm -f "$tmp_home" "$tmp_gke" "$tmp_off" "$tmp_tail"' EXIT
render homelab tests/render/ntfy-xr.yaml     > "$tmp_home"
render gke     tests/render/ntfy-xr.yaml     > "$tmp_gke"
render homelab tests/render/ntfy-xr-off.yaml > "$tmp_off"
render homelab-tailnet tests/render/ntfy-xr.yaml > "$tmp_tail"

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
for f in "$tmp_home" "$tmp_gke" "$tmp_off" "$tmp_tail"; do
    check shape "$f" yes 'name: ntfy'
    check shape "$f" yes 'namespace: ntfy'
done

# No placeholder or stale per-box literal may reach a render: the device name now
# comes from the identity's tailnetNode, never from a stamped claim value.
for f in "$tmp_home" "$tmp_gke" "$tmp_off" "$tmp_tail"; do
    check placeholder "$f" no 'ntfy-MACHINE'
    check placeholder "$f" no 'ntfy-loki'
done

# Tailnet exposure follows the identity's tailnetNode, not the environment: an
# identity without one (plain homelab) is not exposed and has no base-url.
check homelab "$tmp_home" no 'tailscale.com/hostname'
check homelab "$tmp_home" no 'tailscale.com/expose'
check homelab "$tmp_home" no 'base-url:'

# The gke fixture mirrors clusters/gke-prod.yaml (tailnetNode: gke): the
# production path exposes as ntfy-gke.
check gke "$tmp_gke" yes 'tailscale.com/hostname: ntfy-gke'
check gke "$tmp_gke" yes 'tailscale.com/expose'
check gke "$tmp_gke" yes 'base-url: "http://ntfy-gke.tailf5b47a.ts.net"'

# A homelab identity WITH a tailnetNode exposes as ntfy-<tailnetNode>.
check tailnet "$tmp_tail" yes 'tailscale.com/expose'
check tailnet "$tmp_tail" yes 'tailscale.com/hostname: ntfy-homelab-test-20261113-1430'
check tailnet "$tmp_tail" yes 'tailscale.com/tags: tag:ntfy'
check tailnet "$tmp_tail" yes 'base-url: "http://ntfy-homelab-test-20261113-1430.tailf5b47a.ts.net"'
check tailnet "$tmp_tail" yes 'replicas: 1'

[[ $fail -eq 0 ]] && echo "ntfy render checks: PASS"
exit $fail
