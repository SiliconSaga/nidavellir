#!/usr/bin/env bash
# Offline render check for the OpenBao composition's seal seams. Requires
# Docker and the crossplane CLI (realm docs/dev-setup.md). Run from the
# nidavellir repo root:
#   bash tests/render/check-openbao.sh
set -euo pipefail

command -v crossplane >/dev/null || { echo "crossplane CLI not on PATH — install from https://docs.crossplane.io/latest/cli/" >&2; exit 1; }

render() { # $1=env $2=xr-file
    crossplane render "$2" openbao/composition.yaml \
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

tmp_home=$(mktemp "${TMPDIR:-/tmp}/openbao-home.XXXXXX") tmp_gke=$(mktemp "${TMPDIR:-/tmp}/openbao-gke.XXXXXX") tmp_shamir=$(mktemp "${TMPDIR:-/tmp}/openbao-shamir.XXXXXX")
trap 'rm -f "$tmp_home" "$tmp_gke" "$tmp_shamir"' EXIT
render homelab tests/render/openbao-xr.yaml > "$tmp_home"
render gke     tests/render/openbao-xr.yaml > "$tmp_gke"
render gke     tests/render/openbao-xr-shamir.yaml > "$tmp_shamir"

# homelab: static seal fed from the openbao-seal-key Secret; no KMS, no WI annotation.
check homelab "$tmp_home" yes 'seal "static"'
check homelab "$tmp_home" yes 'current_key    = "env://BAO_SEAL_STATIC_KEY"'
check homelab "$tmp_home" yes 'secretName: openbao-seal-key'
check homelab "$tmp_home" no  'seal "gcpckms"'
check homelab "$tmp_home" no  'iam.gke.io/gcp-service-account'
check homelab "$tmp_home" no  'serviceAccount:'

# gke: KMS seal with coordinates from cluster-identity; WI annotation on the KSA; no static key.
check gke "$tmp_gke" yes 'seal "gcpckms"'
check gke "$tmp_gke" yes 'project    = "example-project"'
check gke "$tmp_gke" yes 'region     = "us-east1"'
check gke "$tmp_gke" yes 'key_ring   = "openbao"'
check gke "$tmp_gke" yes 'crypto_key = "unseal"'
check gke "$tmp_gke" yes 'iam.gke.io/gcp-service-account: openbao-seal@example-project.iam.gserviceaccount.com'
# The annotation must sit under the chart's server.serviceAccount, not on the
# Release or the HTTPRoute Object: `serviceAccount:` appears in the render ONLY
# when that values block was emitted, so its presence here (and absence on the
# other two renders below) anchors where the annotation landed.
check gke "$tmp_gke" yes 'serviceAccount:'
check gke "$tmp_gke" no  'seal "static"'
check gke "$tmp_gke" no  'BAO_SEAL_STATIC_KEY'

# seal: shamir opt-out renders no seal stanza at all, on either environment.
check shamir "$tmp_shamir" no 'seal "gcpckms"'
check shamir "$tmp_shamir" no 'seal "static"'
check shamir "$tmp_shamir" no 'iam.gke.io/gcp-service-account'
check shamir "$tmp_shamir" no 'serviceAccount:'

# snapshot agent: enabled on every environment and under either seal, with
# the per-environment S3 target. The Secret name and role are contracts with
# nordri (bootstrap Layer 5 / gke-provision.sh openbao-backup-setup, and
# lib/openbao.sh's openbao-backup role).
agent_enabled() { # $1=render file — `enabled: true` inside the snapshotAgent block itself
    sed -n '/^ *snapshotAgent:/,/^ *server:/p' "$1" | grep -Fq 'enabled: true'
}
for f in "$tmp_home" "$tmp_gke" "$tmp_shamir"; do
    check agent "$f" yes 'snapshotAgent:'
    if ! agent_enabled "$f"; then echo "FAIL [agent]: snapshotAgent block lacks enabled: true in $f" >&2; fail=1; fi
    check agent "$f" yes 's3CredentialsSecret: openbao-backup-s3'
    check agent "$f" yes 'baoRole: openbao-backup'
    check agent "$f" yes 'baoAuthPath: kubernetes'
    check agent "$f" yes '0 5 * * *'
done
# Retention: the agent expires objects only on homelab (Garage has no lifecycle
# rule); on gke the bucket lifecycle rule does it and the identity cannot delete.
check homelab "$tmp_home" yes 's3ExpireDays: "30"'
check gke "$tmp_gke" no  's3ExpireDays: "30"'
check gke "$tmp_gke" yes 's3ExpireDays: ""'
check gke "$tmp_gke" yes 's3Uri: s3://example-project-openbao-backups/openbao/'
check gke "$tmp_gke" yes 's3Host: storage.googleapis.com'
check gke "$tmp_gke" yes 's3Bucket: storage.googleapis.com'
check gke "$tmp_gke" yes 's3cmdExtraFlag: --signature-v2'
check gke "$tmp_gke" no  'garage.garage.svc'
check homelab "$tmp_home" yes 's3Uri: s3://openbao-backups/openbao/'
check homelab "$tmp_home" yes 's3Host: garage.garage.svc.cluster.local:3900'
check homelab "$tmp_home" yes 's3Bucket: garage.garage.svc.cluster.local:3900'
check homelab "$tmp_home" yes 's3cmdExtraFlag: --no-ssl --region=garage'
check homelab "$tmp_home" no  'storage.googleapis.com'

# unchanged seams from before this change
check homelab "$tmp_home" yes 'storageClass: local-path'
check gke     "$tmp_gke"  yes 'openbao.cmdbee.org'

[[ $fail -eq 0 ]] && echo "openbao render checks: PASS"
exit $fail
