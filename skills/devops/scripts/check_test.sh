#!/usr/bin/env bash
# Tests for the layer logic of check.sh. No SSH: each case feeds a facts file
# through CHECK_FACTS_FILE and asserts the final LAYER line and the exit code.
#   bash check_test.sh
set -euo pipefail

CHECK="$(dirname "$0")/check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

# Facts of a healthy server after vps-init + web-init with one project deployed.
WEB_OK='hard_conf=1
sshd_permitrootlogin=no
sshd_passwordauthentication=no
sshd_allowusers=ops deployer
ufw_active=1
ufw_allow=22/tcp
ufw_allow=80/tcp
ufw_allow=443/tcp
f2b_active=1
f2b_sshd=1
web_anchor=1
docker_active=1
compose_version=2.40.3
daemon_log_driver=json-file
daemon_max_size=10m
daemon_live_restore=true
proxy_net=1
container=traefik-traefik-1|traefik|traefik|0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, [::]:443->443/tcp|
container=traefik-socket-proxy-1|traefik|socket-proxy|2375/tcp|/var/run/docker.sock
container=myapp-web-1|myapp|web|8000/tcp|
container=myapp-postgres-1|myapp|postgres|5432/tcp|
deployer_exists=1
deployer_locked=1
deployer_groups=deployer docker
deployer_sudo=0
deployer_keys_owner=root:755 root:755 root:644
deploy_app=root:755
prune_enabled=1
prune_active=1
vpn_signal=
auto_reboot=1
env_image=myapp|1
disk_used=41'

# Facts of a VPN server: vps-init done, xray on 443 as a host process, no Docker.
VPS_OK='hard_conf=1
sshd_permitrootlogin=no
sshd_passwordauthentication=no
sshd_allowusers=ops
ufw_active=1
ufw_allow=22/tcp
ufw_allow=443/tcp
f2b_active=1
f2b_sshd=1
web_anchor=0
docker_active=0
vpn_signal=systemd:xray.service
auto_reboot=0
disk_used=20'

FRESH='hard_conf=0
sshd_permitrootlogin=yes
sshd_passwordauthentication=yes
sshd_allowusers=
ufw_active=0
f2b_active=0
f2b_sshd=0
web_anchor=0
docker_active=0
disk_used=5'

# case <name> <facts> <expected last line regex> <expected exit code> [<WARN lines>]
# The WARN count defaults to 0: a healthy server prints no WARN line.
case_() {
  local name=$1 facts=$2 want=$3 want_rc=$4 want_warn=${5:-0} out rc=0 warns
  printf '%s\n' "$facts" > "$TMP/facts"
  out=$(DEVOPS_CONFIG=/dev/null DEVOPS_ADMIN=ops CHECK_FACTS_FILE="$TMP/facts" bash "$CHECK" test-host) || rc=$?
  warns=$(grep -c '^  WARN  ' <<<"$out" || true)
  if [[ $(tail -n1 <<<"$out") =~ $want && $rc -eq $want_rc && $warns -eq $want_warn ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), WARN=$warns (want $want_warn), last line: $(tail -n1 <<<"$out")"
    printf '%s\n' "$out" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}

case_ "web layer healthy"          "$WEB_OK" '^LAYER=web FAIL=0 PROJECTS=myapp$' 0
case_ "vpn server = vps layer"     "$VPS_OK" '^LAYER=vps FAIL=0 PROJECTS=$' 0
case_ "fresh server = none"        "$FRESH"  '^LAYER=none FAIL=0 PROJECTS=$' 0
case_ "root login on hardened"     "${VPS_OK/sshd_permitrootlogin=no/sshd_permitrootlogin=yes}" '^LAYER=vps FAIL=1 ' 1
case_ "password auth on hardened"  "${VPS_OK/sshd_passwordauthentication=no/sshd_passwordauthentication=yes}" '^LAYER=vps FAIL=1 ' 1
case_ "admin not in AllowUsers"    "${VPS_OK/sshd_allowusers=ops/sshd_allowusers=bob}" 'FAIL=1 ' 1
case_ "ufw off on hardened"        "${VPS_OK/ufw_active=1/ufw_active=0}" 'FAIL=1 ' 1
case_ "fail2ban off"               "${VPS_OK/f2b_active=1/f2b_active=0}" 'FAIL=1 ' 1
case_ "app publishes on 0.0.0.0" \
  "$WEB_OK
container=evil-db-1|evil|db|0.0.0.0:5432->5432/tcp|" '^LAYER=web FAIL=1 PROJECTS=evil,myapp$' 1
case_ "app publishes on [::] only" \
  "$WEB_OK
container=evil-db-1|evil|db|[::]:5432->5432/tcp|" 'FAIL=1 ' 1
case_ "127.0.0.1 binding is fine" \
  "$WEB_OK
container=tools-db-1|tools|db|127.0.0.1:5432->5432/tcp|" '^LAYER=web FAIL=0 PROJECTS=myapp,tools$' 0
case_ "socket mounted into app" \
  "$WEB_OK
container=portainer|portainer|portainer|9000/tcp|/var/run/docker.sock" 'FAIL=1 ' 1
case_ "public port without web layer" \
  "$VPS_OK
container=old-traefik|old|traefik|0.0.0.0:80->80/tcp|" '^LAYER=vps FAIL=1 ' 1
case_ "traefik stack down"         "$(grep -v '^container=traefik-traefik-1' <<<"$WEB_OK")" 'FAIL=1 ' 1
case_ "compose v5 is fine"         "${WEB_OK/compose_version=2.40.3/compose_version=5.5.1}" '^LAYER=web FAIL=0 ' 0
case_ "no compose plugin"          "${WEB_OK/compose_version=2.40.3/compose_version=}" 'FAIL=1 ' 1
case_ "no proxy network"          "${WEB_OK/proxy_net=1/proxy_net=0}" 'FAIL=1 ' 1
case_ "no log rotation"            "${WEB_OK/daemon_max_size=10m/daemon_max_size=}" 'FAIL=1 ' 1
case_ "deployer has sudo"          "${WEB_OK/deployer_sudo=0/deployer_sudo=1}" 'FAIL=1 ' 1
case_ "deployer in sudo group"     "${WEB_OK/deployer_groups=deployer docker/deployer_groups=deployer docker sudo}" 'FAIL=1 ' 1
case_ "deployer not in AllowUsers" "${WEB_OK/sshd_allowusers=ops deployer/sshd_allowusers=ops}" 'FAIL=1 ' 1
case_ "deployer owns its .ssh"     "${WEB_OK/root:755 root:755 root:644/root:755 deployer:700 root:644}" 'FAIL=1 ' 1
case_ "deployer owns its home"     "${WEB_OK/root:755 root:755 root:644/deployer:750 root:755 root:644}" 'FAIL=1 ' 1
case_ "no deploy-app"              "${WEB_OK/deploy_app=root:755/deploy_app=}" 'FAIL=1 ' 1
case_ "deploy-app writable"        "${WEB_OK/deploy_app=root:755/deploy_app=deployer:755}" 'FAIL=1 ' 1
case_ "prune timer off"            "${WEB_OK/prune_active=1/prune_active=0}" 'FAIL=1 ' 1
case_ "ufw 443 closed on web"      "$(grep -v '^ufw_allow=443/tcp' <<<"$WEB_OK")" 'FAIL=1 ' 1
case_ "web without vps = none"     "${WEB_OK/hard_conf=1/hard_conf=0}" '^LAYER=none ' 0
case_ "no auto-reboot off VPN"     "${WEB_OK/auto_reboot=1/auto_reboot=0}" '^LAYER=web FAIL=0 PROJECTS=myapp$' 0 1
case_ "auto-reboot on VPN"         "${VPS_OK/auto_reboot=0/auto_reboot=1}" '^LAYER=vps FAIL=0 PROJECTS=$' 0 1
case_ "legacy facts: no auto-reboot keys" "$(grep -vE '^(vpn_signal|auto_reboot)=' <<<"$WEB_OK")" '^LAYER=web FAIL=0 ' 0 1
case_ "fresh server: no auto-reboot WARN" "$FRESH" '^LAYER=none FAIL=0 ' 0 0
case_ "web project without IMAGE" "${WEB_OK/env_image=myapp|1/env_image=myapp|0}" '^LAYER=web FAIL=0 PROJECTS=myapp$' 0 1
case_ "web project without .env"  "${WEB_OK/env_image=myapp|1/env_image=myapp|}" '^LAYER=web FAIL=0 ' 0 0
case_ "vps layer: no IMAGE check" "$VPS_OK
env_image=myapp|0" '^LAYER=vps FAIL=0 ' 0 0

# The IMAGE WARN names the app and gives the line to add: from the config
# when the registry is known, else the generic form.
image_warn() {  # image_warn <name> <expected IMAGE value> <env assignments...>
  local name=$1 want=$2 out line
  shift 2
  printf '%s\n' "${WEB_OK/env_image=myapp|1/env_image=myapp|0}" > "$TMP/facts"
  out=$(env DEVOPS_CONFIG=/dev/null DEVOPS_ADMIN=ops CHECK_FACTS_FILE="$TMP/facts" "$@" bash "$CHECK" test-host || true)
  line=$(grep '^  WARN  ' <<<"$out" || true)
  if [[ $line == "  WARN  myapp: no IMAGE in /opt/myapp/.env, deploy-app cannot roll out without it: add IMAGE=$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: got «${line}»"
    FAILED=$((FAILED + 1))
  fi
}
image_warn "IMAGE hint: generic form"  "<registry>/<owner>/myapp"
image_warn "IMAGE hint: Forgejo"       "registry.example/acme/myapp" DEVOPS_REGISTRY=registry.example DEVOPS_REGISTRY_USER=acme
image_warn "IMAGE hint: GitHub"        "ghcr.io/acme/myapp" DEVOPS_FORGE=github DEVOPS_REGISTRY_USER=Acme

# vps-init and check.sh carry the same vpn_signal(): the remote heredocs
# cannot source a shared file, so the copies must stay identical.
fn() { sed -n '/^vpn_signal() {$/,/^}$/p' "$1"; }
VPS_INIT="$(dirname "$0")/../bin/vps-init"
if [[ -n $(fn "$CHECK") ]] && diff <(fn "$VPS_INIT") <(fn "$CHECK") >/dev/null; then
  echo "ok   vpn_signal() same in vps-init and check.sh"
else
  echo "FAIL vpn_signal() differs between vps-init and check.sh (or is missing)"
  FAILED=$((FAILED + 1))
fi

# vpn_signal() on a host with no VPN prints nothing and returns 0 under set -e,
# with systemctl, docker and xray shimmed; each shim then flips one signal on.
mkdir -p "$TMP/bin"
SIG_FN=$(fn "$CHECK")
signal() {  # signal <systemctl output> <docker output>
  printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$1" > "$TMP/bin/systemctl"
  printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$2" > "$TMP/bin/docker"
  chmod +x "$TMP/bin/systemctl" "$TMP/bin/docker"
  PATH="$TMP/bin:/usr/bin:/bin" bash -c "set -euo pipefail; $SIG_FN
vpn_signal; echo rc=\$?"
}
sig_case() {
  local name=$1 want=$2 got
  got=$(signal "$3" "$4" | xargs)
  if [[ $got == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: got «$got», want «$want»"; FAILED=$((FAILED + 1)); fi
}
sig_case "vpn_signal: none"            "rc=0" "" "traefik-traefik-1 traefik:v3.5"
sig_case "vpn_signal: xray unit"       "systemd:xray.service rc=0" "xray.service enabled enabled" ""
sig_case "vpn_signal: wg-quick unit"   "systemd:wg-quick@wg0.service rc=0" "wg-quick@wg0.service enabled enabled" ""
sig_case "vpn_signal: xray container"  "docker:xray-vless rc=0" "" "xray-vless teddysun/xray:latest"
sig_case "vpn_signal: amnezia image"   "docker:amnezia-awg rc=0" "" "amnezia-awg amneziavpn/amnezia-wg:latest"

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
