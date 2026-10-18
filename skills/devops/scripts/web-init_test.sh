#!/usr/bin/env bash
# Tests for the daemon.json merge of web-init. No SSH: the daemon_json()
# function is cut out of the remote heredoc and fed sample files.
#   bash web-init_test.sh
set -euo pipefail

WEB_INIT="$(dirname "$0")/../bin/web-init"
FN=$(sed -n '/^daemon_json() {/,/^}$/p' "$WEB_INIT")
FAILED=0
[[ -n $FN ]] || { echo "FAIL no daemon_json() in web-init"; exit 1; }
eval "$FN"

# merge <name> <old daemon.json> <jq filter that must be true on the result>
merge() {
  local name=$1 old=$2 want=$3 got
  got=$(daemon_json <<<"$old")
  if jq -e "$want" <<<"$got" >/dev/null; then
    echo "ok   $name"
  else
    echo "FAIL $name: got $(jq -c . <<<"$got")"
    FAILED=$((FAILED + 1))
  fi
}

WANT='."log-driver" == "journald" and ."log-opts" == {"tag":"{{.Name}}"} and ."live-restore" == true'
merge "empty file"   '{}' "$WANT and length == 3"
# json-file options left under log-opts make dockerd refuse the journald driver.
merge "old json-file rotation is replaced" \
  '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true}' "$WANT and length == 3"
merge "other keys are kept" \
  '{"log-driver":"json-file","log-opts":{"max-size":"10m"},"registry-mirrors":["https://m.example"],"default-address-pools":[{"base":"10.10.0.0/16","size":24}]}' \
  "$WANT and .\"registry-mirrors\" == [\"https://m.example\"] and .\"default-address-pools\"[0].size == 24 and length == 5"
merge "live-restore false is turned on" '{"live-restore":false}' "$WANT"
# Same output for an already merged file: web-init restarts docker only on a difference.
merged=$(daemon_json <<<'{"log-driver":"json-file","log-opts":{"max-size":"10m"},"debug":true}')
merge "second run changes nothing" "$merged" ". == $(jq -c . <<<"$merged")"
if [[ $(daemon_json <<<"$merged") == "$merged" ]]; then echo "ok   output is byte-stable"
else echo "FAIL output differs on the second run"; FAILED=$((FAILED + 1)); fi

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
