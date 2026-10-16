#!/usr/bin/env bash
# Tests for .githooks/pre-commit in a throwaway repository: a staged private
# marker stops the commit, a clean commit passes, a staged secret stops it
# (gitleaks), and a missing marker list only prints a notice.
#   bash .githooks/pre-commit_test.sh
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/pre-commit"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

printf '%s\n' '# comment line' '' 'secret-codename' 'home\.example\.net' > "$TMP/markers"

# case_ <name> <expected exit code> <expected output regex> <marker list> <file content>
# Stages one file with the content in a fresh repository (no commit yet, as
# before a first commit) and runs the hook. The marker text itself must never
# appear in the output.
case_() {
  local name=$1 want_rc=$2 want=$3 markers=$4 content=$5 repo out rc=0
  repo=$(mktemp -d "$TMP/repo.XXXX")
  git -C "$repo" init -q
  printf '%s\n' "$content" > "$repo/file.txt"
  git -C "$repo" add file.txt
  out=$(cd "$repo" && DEVOPS_PRIVATE_MARKERS=$markers bash "$HOOK" 2>&1) || rc=$?
  if [[ $rc -eq $want_rc && $out =~ $want && ! $out =~ [Cc]odename ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), output does not match /$want/"
    printf '%s\n' "$out" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}

case_ "clean file passes" 0 "markers: 2 patterns, no hits" "$TMP/markers" "plain text"
case_ "marker stops the commit" 1 "file.txt:1: matches a private marker" "$TMP/markers" "built for Secret-Codename"
case_ "dotted marker is a regex" 1 "file.txt:1:" "$TMP/markers" "ssh ops@home.example.net"
case_ "missing marker list: notice, gitleaks only" 0 "marker list $TMP/none is missing" "$TMP/none" "plain text"
case_ "secret stops the commit" 1 "gitleaks" "$TMP/markers" "token = \"ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)\""

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
