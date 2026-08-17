#!/usr/bin/env bash
# Behaviour test for the ntfy heimdall message template.
#
# Why this exists: the template renders server-side, so a mistake in it does not
# fail a deploy — it silently degrades or kills every notification. This runs a
# throwaway ntfy container, feeds it a realistic AlertManager webhook envelope,
# and asserts on what a phone would actually receive. Seconds, no cluster.
#
# Usage:  bash ntfy/test-template.sh
# Needs:  docker, yq, curl
#
# The template is copied into the running container rather than bind-mounted:
# mounts are the fiddly part on Windows (Rancher Desktop's VM sees drives under
# /mnt/<drive>/, and Git Bash mangles path arguments to raw docker), and none of
# that is worth carrying in a test that should just work everywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGMAP="${SCRIPT_DIR}/heimdall-template.yaml"
NAME="ntfy-template-test-$$"
PORT="${NTFY_TEST_PORT:-8099}"
IMAGE="binwiederhier/ntfy:v2.23.0"
DOCKER="${DOCKER:-docker}"

cleanup() { $DOCKER rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

TMP="$(mktemp -d)"
yq eval '.data."heimdall.yml"' "$CONFIGMAP" > "${TMP}/heimdall.yml"

cat > "${TMP}/payload.json" <<'EOF'
{
  "status": "firing",
  "commonLabels": { "alertname": "TargetDown", "severity": "warning" },
  "alerts": [
    { "labels": { "namespace": "heimdall" },
      "annotations": {
        "summary": "One or more targets are unreachable.",
        "description": "25% of the node-exporter targets in heimdall namespace are down."
      } },
    { "labels": { "namespace": "openbao" },
      "annotations": { "summary": "Fallback when no description is set." } }
  ]
}
EOF

$DOCKER run -d --name "$NAME" -p "${PORT}:80" "$IMAGE" serve \
  --base-url "http://localhost:${PORT}" --listen-http :80 >/dev/null

for _ in $(seq 1 30); do
  curl -sf "http://localhost:${PORT}/v1/health" >/dev/null 2>&1 && break
  sleep 1
done

# Container-side paths are kept inside a quoted `sh -c` string so that Git Bash
# (MSYS) never sees an argument beginning with `/` and therefore never rewrites
# it. Piping the file in on stdin avoids `docker cp`, whose source and
# destination want opposite path conventions on Windows.
$DOCKER exec "$NAME" sh -c 'mkdir -p /etc/ntfy/templates'
$DOCKER exec -i "$NAME" sh -c 'cat > /etc/ntfy/templates/heimdall.yml' < "${TMP}/heimdall.yml"

RESULT="$(curl -s -X POST "http://localhost:${PORT}/testtopic?template=heimdall" \
  -H "Content-Type: application/json" --data-binary "@${TMP}/payload.json")"

echo "rendered: $RESULT"
echo

fail() { echo "FAIL: $1"; exit 1; }

# The whole point of the template: chart alerts put specifics in `description`
# and only a generic sentence in `summary`, so rendering summary alone produces
# notifications with no pod, namespace or cause in them.
case "$RESULT" in
  *"25% of the node-exporter targets in heimdall namespace are down."*) ;;
  *) fail "description not rendered — notifications would lack all detail" ;;
esac

# Alerts without a description must still say something.
case "$RESULT" in
  *"Fallback when no description is set."*) ;;
  *) fail "summary fallback not rendered — such alerts would be blank" ;;
esac

# severity=warning must map to ntfy priority 3, not the DND-piercing 5.
case "$RESULT" in
  *'"priority":3'*) ;;
  *) fail "warning did not map to priority 3" ;;
esac

case "$RESULT" in
  *'"title":"TargetDown [firing]"'*) ;;
  *) fail "title did not render alertname and status" ;;
esac

echo "PASS: description rendered, summary fallback works, severity mapped to priority 3"
