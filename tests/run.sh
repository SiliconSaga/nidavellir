#!/usr/bin/env bash
# nidavellir test/lint runner — invoked by the ws adapter (realm adapters/nidavellir.yaml).
# Cluster-free: syntax-checks the shell scripts, runs the shell unit tests under
# tests/scripts/, and runs every offline render check under tests/render/
# (`crossplane render` and `kubectl kustomize`, both local, no cluster). The
# kuttl suites under tests/platform/ and tests/e2e/ need a live cluster and are
# run separately, NOT here.
#
# Usage: tests/run.sh [test|lint]   (default: test)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # nidavellir repo root
shopt -s nullglob   # an empty glob drops out instead of passing the literal pattern

mode="${1:-test}"
shell_files=(forgejo/scripts/*.sh tests/render/*.sh tests/scripts/*.sh tests/run.sh)

syntax_check() {
  local f rc=0
  for f in "${shell_files[@]}"; do
    if ! bash -n "$f"; then echo "  bash -n FAILED: $f" >&2; rc=1; fi
  done
  return $rc
}

case "$mode" in
  lint)
    if command -v shellcheck >/dev/null 2>&1; then
      shellcheck "${shell_files[@]}"
    else
      echo "shellcheck not installed — falling back to 'bash -n' syntax lint."
      syntax_check
    fi
    ;;
  test)
    echo "== syntax check =="
    syntax_check || exit 1
    for tool in crossplane kubectl; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ $tool is required for the render checks (offline: crossplane render / kubectl kustomize). Install it and re-run." >&2
        exit 1
      fi
    done
    fails=0
    echo "== shell unit tests =="
    for t in tests/scripts/*-test.sh; do
      echo "RUN $t"
      bash "$t" || fails=$((fails + 1))
    done
    echo "== render checks =="
    for t in tests/render/check-*.sh; do
      echo "RUN $t"
      bash "$t" || fails=$((fails + 1))
    done
    if [ "$fails" -ne 0 ]; then
      echo "❌ $fails test file(s) FAILED" >&2
      exit 1
    fi
    echo "✅ nidavellir: syntax clean + unit tests + render checks pass"
    ;;
  *)
    echo "Usage: tests/run.sh [test|lint]" >&2
    exit 2
    ;;
esac
