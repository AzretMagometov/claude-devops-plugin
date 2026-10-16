#!/usr/bin/env bash
# End-to-end test of vpn-deploy on a fresh throwaway Ubuntu with systemd
# inside a privileged local container, without web-init, Docker or Traefik:
#
#   vpn-deploy <host> 1  (vps-init → xray VLESS Reality → client config)
#
# Checks: step 1 (vps-init) turns auto-reboot on, as on a fresh server, and
# step 2 removes it after xray; one client config downloaded; a real Reality
# connection through the server (xray-clients test); check.sh without WARN.
#
#   bash integration_vpn_test.sh    # ~3 min, needs internet and Docker
set -euo pipefail

NAME=vpn-deploy-it
# shellcheck source=SCRIPTDIR/integration_lib.sh
. "$(dirname "$0")/integration_lib.sh"

say "fresh server without the web layer"
check "no Docker, no /opt/traefik" ssh "root@$HOST" '! command -v docker && ! test -e /opt/traefik'

say "vpn-deploy: fresh node without VPN signals → xray → no auto-reboot"
mkdir "$W/home"
rc=0; OUT=$(HOME="$W/home" "$SKILL/bin/vpn-deploy" "$HOST" 1 2>&1) || rc=$?
printf '%s\n' "$OUT" | grep -E '^(===|✓|Auto-reboot|Error)' || true
# The filter above hides the cause of a failure: show the end of the full output.
[[ $rc -eq 0 ]] || { echo "--- vpn-deploy exit ${rc}, last 40 lines:"; printf '%s\n' "$OUT" | tail -n 40; }
check "vpn-deploy succeeds" test "$rc" -eq 0
check "vpn-deploy: step 1 turned auto-reboot on" grep -q '^✓ .*auto-reboot: 04:00' <<<"$OUT"
check "vpn-deploy: step 2 prints why auto-reboot is off" grep -q '^Auto-reboot removed: VPN node' <<<"$OUT"
check "vpn-deploy: 52-auto-reboot removed" admin "! test -e /etc/apt/apt.conf.d/52-auto-reboot"
check "vpn-deploy: Reality connection through the server" grep -q "^✓ tunnel through 'user-01' works" <<<"$OUT"
check "vpn-deploy: one client config downloaded" test "$(find "$W/home/vpn-configs/$HOST" -name 'user-*.txt' | wc -l | xargs)" = 1

OUT=$(bash "$SKILL/scripts/check.sh" "$HOST") || true
printf '%s\n' "$OUT" | grep -E 'FAIL|WARN|LAYER' || true
check "check.sh after vpn-deploy: vps layer, FAIL=0" grep -q '^LAYER=vps FAIL=0 ' <<<"$OUT"
check "check.sh after vpn-deploy: no WARN" no_warn "$OUT"

finish
