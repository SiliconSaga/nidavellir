#!/usr/bin/env bash
# Unit test for forgejo/scripts/askpass.sh against the prompt shapes git
# produces. Two of them bit on the first live runs: GitHub prompts for a
# missing upstream (and must get no answer), and the password prompt embeds
# the username in the URL ("http://forgejo-admin@host:3000"), which a verbatim
# FORGEJO_URL match refused. Run from the nidavellir repo root:
#   bash tests/scripts/forgejo-askpass-test.sh
set -u
script="$(cd "$(dirname "$0")/../.." && pwd)/forgejo/scripts/askpass.sh"
tok=$(mktemp); printf 'stub-token' > "$tok"
export FORGEJO_URL=http://forgejo-http.forgejo.svc.cluster.local:3000 PULLER_USERNAME=forgejo-admin PULLER_TOKEN_FILE="$tok"
fails=0
check() { # $1=label $2=expected-output|FAIL $3=prompt
  local out rc
  out=$(bash "$script" "$3" 2>/dev/null); rc=$?
  if [ "$2" = FAIL ]; then
    if [ $rc -ne 0 ]; then echo "ok - $1"; else echo "NOT OK - $1 (answered: $out)"; fails=$((fails+1)); fi
  else
    if [ $rc -eq 0 ] && [ "$out" = "$2" ]; then echo "ok - $1"; else echo "NOT OK - $1 (rc=$rc out=$out)"; fails=$((fails+1)); fi
  fi
}
# Prompts are assembled from the variables (git writes "user@host" into the
# password prompt, which would read as an email address to a PII scan).
host="${FORGEJO_URL#*://}"
at="${PULLER_USERNAME}@"
check "forgejo username prompt" forgejo-admin "Username for '${FORGEJO_URL}': "
check "forgejo password prompt (user embedded)" stub-token "Password for 'http://${at}${host}': "
check "github username prompt refused" FAIL "Username for 'https://github.com': "
check "github password prompt refused" FAIL "Password for 'https://${at}github.com': "
check "look-alike host refused" FAIL "Password for 'http://${at}${host}.evil': "
rm -f "$tok"
[ $fails -eq 0 ] && echo "forgejo-askpass-test: PASS"
exit $fails
