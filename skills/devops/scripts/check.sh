#!/usr/bin/env bash
# Which server layers are in place and whether they hold their contract.
#
#   check.sh <IP or ssh alias>
#
# Layers, each anchored on the file its init script creates:
#   vps  vps-init  /etc/ssh/sshd_config.d/00-hardening.conf
#   web  web-init  /opt/traefik/compose.yml
# A missing anchor means the layer is not installed yet: that is state, not an
# error. A present anchor with a failed assertion means the layer is broken.
# The vps layer also compares auto-reboot with VPN detection; a mismatch is a
# WARN line, not counted in FAIL. On LAYER=web a project whose /opt/<app>/.env
# has no IMAGE line is a WARN too: deploy-app cannot roll it out. So is a .env
# that is not root:deployer 640, as add-project.sh leaves it.
# Two findings are errors on any layer: a container other than Traefik that
# publishes a port on all interfaces, and a container other than socket-proxy
# that mounts the Docker socket.
#
# Last line of the output, for the caller to parse:
#   LAYER=<none|vps|web> FAIL=<n> PROJECTS=<compose projects, comma-separated>
#   LAYER=none ROOT_KEY=<yes|no>     the admin has no access yet (fresh server)
# Exit code:
#   0  the check ran and nothing installed is broken (any LAYER)
#   1  an installed layer is broken (FAIL > 0)
#   2  no connection, changed host key, the remote check could not run,
#      or DEVOPS_ADMIN is not set
#
# All remote commands are read-only. They run as DEVOPS_ADMIN (~/.config/devops/env)
# with `sudo -n`; the user comes from there, the address and port from ~/.ssh/config if HOST is an alias.
# CHECK_FACTS_FILE=<file> skips SSH and evaluates a saved facts file (tests).
set -euo pipefail

f=$0; while [ -L "$f" ]; do t=$(readlink "$f"); case $t in /*) f=$t ;; *) f=$(dirname "$f")/$t ;; esac; done
DEVOPS_DIR=$(cd "$(dirname "$f")/.." && pwd)
# shellcheck source=SCRIPTDIR/../lib/config.sh
. "$DEVOPS_DIR/lib/config.sh"
devops_require DEVOPS_ADMIN || exit 2
ADMIN=$DEVOPS_ADMIN
[ $# -eq 1 ] || { echo "usage: $(basename "$0") <IP or ssh alias>" >&2; exit 2; }
HOST=$1
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

# Prints key=value facts. Repeated keys (ufw_allow, container) are lists.
collect() {
  cat <<'REMOTE'
set -uo pipefail
f() { printf '%s=%s\n' "$1" "$2"; }
yn() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
# First VPN signal on this host, or nothing: a restart tears down the tunnels,
# so such a host must not reboot itself. Same text in vps-init and check.sh.
vpn_signal() {
  local s
  s=$(systemctl list-unit-files --no-legend 'xray*.service' 'x-ui.service' 's-ui.service' 'amnezia*.service' \
    'wg-quick@?*.service' 'awg-quick@?*.service' 2>/dev/null | awk 'NR==1{print $1}' || true)
  [ -z "$s" ] || { echo "systemd:$s"; return 0; }
  if command -v docker >/dev/null 2>&1; then
    s=$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -iE -m1 'xray|amnezia|awg|wireguard|x-ui|s-ui' | cut -d' ' -f1 || true)
    [ -z "$s" ] || { echo "docker:$s"; return 0; }
  fi
  for s in /sys/class/net/wg[0-9]* /sys/class/net/awg[0-9]* /usr/local/s-ui /usr/local/x-ui /usr/local/etc/xray /opt/amnezia; do
    [ -e "$s" ] || continue
    case $s in /sys/*) echo "iface:${s##*/}" ;; *) echo "path:$s" ;; esac
    return 0
  done
  if command -v xray >/dev/null 2>&1; then echo "bin:xray"; fi
  return 0
}

f hard_conf "$(yn test -f /etc/ssh/sshd_config.d/00-hardening.conf)"
T=$(sshd -T 2>/dev/null)
f sshd_permitrootlogin "$(awk '$1=="permitrootlogin"{print $2}' <<<"$T")"
f sshd_passwordauthentication "$(awk '$1=="passwordauthentication"{print $2}' <<<"$T")"
f sshd_allowusers "$(awk '$1=="allowusers"{for(i=2;i<=NF;i++)print $i}' <<<"$T" | xargs)"

f ufw_active "$(ufw status 2>/dev/null | grep -qx 'Status: active' && echo 1 || echo 0)"
ufw status 2>/dev/null | awk '$2=="ALLOW" || $3=="ALLOW" {print $1}' | sort -u | while read -r r; do f ufw_allow "$r"; done
f f2b_active "$(yn systemctl is-active fail2ban)"
f f2b_sshd "$(yn fail2ban-client status sshd)"
f vpn_signal "$(vpn_signal)"
# Effective value from all of apt.conf.d, not the presence of the vps-init file.
f auto_reboot "$(apt-config dump 2>/dev/null | awk -F'"' '$1=="Unattended-Upgrade::Automatic-Reboot " {v=$2} END {print (tolower(v) ~ /^(true|yes|on|1)$/) ? 1 : 0}')"

f web_anchor "$(yn test -f /opt/traefik/compose.yml)"
f docker_active "$(yn systemctl is-active docker)"
f journald_docker "$(yn test -f /etc/systemd/journald.conf.d/zz-docker-logs.conf)"
if systemctl is-active -q docker 2>/dev/null; then
  f compose_version "$(docker compose version --short 2>/dev/null)"
  DJ=/etc/docker/daemon.json
  if command -v jq >/dev/null && [ -s "$DJ" ]; then
    f daemon_log_driver "$(jq -r '."log-driver" // ""' "$DJ" 2>/dev/null)"
    f daemon_live_restore "$(jq -r '."live-restore" // ""' "$DJ" 2>/dev/null)"
  fi
  f proxy_net "$(yn docker network inspect proxy)"
  docker ps --format '{{.ID}}|{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.Ports}}' |
    while IFS= read -r line; do
      sock=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "${line%%|*}" | tr ' ' '\n' | grep -m1 'docker\.sock$')
      f container "${line#*|}|$sock"
    done
  # Only whether IMAGE is set and the ownership: the rest of .env stays on the server.
  docker ps --format '{{.Label "com.docker.compose.project"}}' | sort -u | while read -r p; do
    case $p in ''|traefik|*[!a-z0-9_-]*) continue ;; esac
    if [ -f "/opt/$p/.env" ]; then
      f env_image "$p|$(yn grep -qE '^IMAGE=.+' "/opt/$p/.env")"
      f env_perms "$p|$(stat -c '%U:%G:%a' "/opt/$p/.env")"
    else f env_image "$p|"; fi
  done
fi

f deployer_exists "$(yn id deployer)"
if id deployer >/dev/null 2>&1; then
  f deployer_locked "$(passwd -S deployer | awk '{print ($2=="L") ? 1 : 0}')"
  f deployer_groups "$(id -nG deployer)"
  f deployer_sudo "$(sudo -l -U deployer 2>/dev/null | grep -q 'is not allowed' && echo 0 || echo 1)"
  f deployer_keys_owner "$(stat -c '%U:%a' /home/deployer /home/deployer/.ssh /home/deployer/.ssh/authorized_keys 2>/dev/null | xargs)"
fi
f deploy_app "$(stat -c '%U:%a' /usr/local/bin/deploy-app 2>/dev/null)"
f prune_enabled "$(yn systemctl is-enabled docker-image-prune.timer)"
f prune_active "$(yn systemctl is-active docker-image-prune.timer)"
f disk_used "$(df --output=pcent / | tail -n1 | tr -dc 0-9)"
REMOTE
}

# --- connection -------------------------------------------------------------
if [ -n "${CHECK_FACTS_FILE:-}" ]; then
  FACTS=$(cat "$CHECK_FACTS_FILE")
else
  ERR=$(mktemp)
  trap 'rm -f "$ERR"' EXIT
  if ! "${SSH[@]}" "$ADMIN@$HOST" true 2>"$ERR"; then
    if grep -q 'IDENTIFICATION HAS CHANGED' "$ERR"; then
      echo "Host key of $HOST changed (VPS reinstalled?). If expected: ssh-keygen -R <IP>" >&2
      exit 2
    fi
    if ! grep -q 'Permission denied' "$ERR"; then
      echo "No connection to $HOST: $(cat "$ERR")" >&2
      exit 2
    fi
    echo "== $HOST: no key login for $ADMIN, vps-init has not run"
    if "${SSH[@]}" "root@$HOST" true 2>/dev/null; then
      echo "   root accepts the key: vps-init can run from here"
      echo "LAYER=none ROOT_KEY=yes"
    else
      echo "   root does not accept the key: vps-init asks for the root password, a terminal is needed"
      echo "LAYER=none ROOT_KEY=no"
    fi
    exit 0
  fi
  if ! FACTS=$(collect | "${SSH[@]}" "$ADMIN@$HOST" 'sudo -n LC_ALL=C.UTF-8 bash -s' 2>"$ERR"); then
    echo "Remote check failed: $(cat "$ERR")" >&2
    exit 2
  fi
fi

# --- evaluation -------------------------------------------------------------
fact() { sed -n "s/^$1=//p" <<<"$FACTS" | head -n1; }
facts() { sed -n "s/^$1=//p" <<<"$FACTS"; }
has_word() { [[ " $1 " == *" $2 "* ]]; }

FAILS=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
note() { echo "  info  $1"; }
# A deviation to show, not counted in FAIL: legacy servers predate the rule.
warn() { echo "  WARN  $1"; }
check() { local msg=$1; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
is() { [ "$(fact "$1")" = "$2" ]; }
ufw_allows() { facts ufw_allow | grep -qxE "$1(/tcp)?"; }
f2b_ok() { is f2b_active 1 && is f2b_sshd 1; }
# Compose 2.35.0 or newer: deploy-app renders a stack with
# `config --no-env-resolution`. Compose went from v2 straight to v5.
COMPOSE_MIN=2.35.0
version_ge() {
  local IFS=. i a b
  read -r -a a <<<"$1"; read -r -a b <<<"$2"
  for i in 0 1 2; do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 0
}
docker_ok() { local v; v=$(fact compose_version); is docker_active 1 && [[ $v =~ ^[0-9]+(\.[0-9]+)*$ ]] && version_ge "$v" "$COMPOSE_MIN"; }
daemon_ok() { is daemon_log_driver journald && is daemon_live_restore true; }
traefik_ok() { has_word "$traefik_services" traefik && has_word "$traefik_services" socket-proxy; }
web_ports_ok() { ufw_allows 80 && ufw_allows 443; }
deployer_ok() { is deployer_exists 1 && is deployer_locked 1; }
deployer_unprivileged() { is deployer_sudo 0 && ! has_word "$(fact deployer_groups)" sudo; }
# Home, .ssh and authorized_keys belong to root: deployer cannot swap its forced command.
deployer_keys_root() { is deployer_keys_owner "root:755 root:755 root:644"; }
prune_ok() { is prune_enabled 1 && is prune_active 1; }

echo "== $HOST"
layer=none
is hard_conf 1 && layer=vps
[ $layer = vps ] && is web_anchor 1 && layer=web

echo "-- vps (vps-init)"
if is hard_conf 1; then
  check "sshd: PermitRootLogin no" is sshd_permitrootlogin no
  check "sshd: PasswordAuthentication no" is sshd_passwordauthentication no
  check "sshd: AllowUsers contains $ADMIN" has_word "$(fact sshd_allowusers)" "$ADMIN"
  check "ufw active" is ufw_active 1
  check "ufw: 22/tcp open" ufw_allows 22
  check "fail2ban active, jail sshd" f2b_ok
  vpn=$(fact vpn_signal)
  if [ -n "$vpn" ]; then
    if is auto_reboot 1; then warn "auto-reboot on for a VPN node ($vpn): a restart breaks the tunnels, rerun vps-init"
    else ok "auto-reboot off: VPN node ($vpn)"; fi
  elif is auto_reboot 1; then ok "auto-reboot after auto-updates at 04:00"
  else warn "auto-reboot off: a new kernel waits for a manual reboot, rerun vps-init"; fi
else
  note "not installed: no 00-hardening.conf"
fi
allowed=$(facts ufw_allow | xargs)
[ -z "$allowed" ] || note "ufw allows: $allowed"

containers=$(facts container)
traefik_services=$(awk -F'|' '$2=="traefik"{print $3}' <<<"$containers" | xargs)

echo "-- web (web-init)"
if is web_anchor 1; then
  check "Docker running, compose plugin $(fact compose_version) (deploy-app needs ${COMPOSE_MIN} or newer; web-init upgrades it)" docker_ok
  check "daemon.json: log-driver journald, live-restore" daemon_ok
  check "journald: container logs kept 30 days / 2G (zz-docker-logs.conf)" is journald_docker 1
  check "network proxy" is proxy_net 1
  check "Traefik stack (project traefik): traefik + socket-proxy" traefik_ok
  check "ufw: 80/tcp and 443/tcp open" web_ports_ok
  check "deployer: exists, password locked" deployer_ok
  check "deployer: no sudo" deployer_unprivileged
  check "deployer: in group docker" has_word "$(fact deployer_groups)" docker
  check "deployer: in AllowUsers" has_word "$(fact sshd_allowusers)" deployer
  check "deployer: home, .ssh, authorized_keys root 755/755/644" deployer_keys_root
  check "/usr/local/bin/deploy-app root 755" is deploy_app root:755
  check "timer docker-image-prune" prune_ok
  # Legacy projects predate IMAGE in .env; the new deploy-app stops without it.
  [ $layer != web ] || facts env_image | while IFS='|' read -r app set; do
    [ "$set" != 0 ] || warn "$app: no IMAGE in /opt/$app/.env, deploy-app cannot roll out without it: add IMAGE=$(devops_image "$app")"
  done
  # A .env recreated by hand (nano, cp) loses root:deployer 640 without a sign.
  [ $layer != web ] || facts env_perms | while IFS='|' read -r app perms; do
    [ "$perms" != root:deployer:640 ] || continue
    env=/opt/$app/.env mode=${perms##*:}
    fix="sudo chown root:deployer $env && sudo chmod 640 $env"
    if (( 8#${mode: -1} & 4 )); then warn "$app: $env is ${perms%:*} $mode, readable by every user on the server: $fix"
    else warn "$app: $env is ${perms%:*} $mode, not root:deployer 640: $fix"; fi
  done
else
  note "not installed: no /opt/traefik/compose.yml"
fi

if [ -n "$containers" ]; then
  echo "-- containers"
  public=$(awk -F'|' '!($2=="traefik" && $3=="traefik") && $4 ~ /(0\.0\.0\.0|\[::\]|::):[0-9]/ {print $1" ("$4")"}' <<<"$containers")
  if [ -z "$public" ]; then ok "only Traefik publishes on all interfaces"; else
    while IFS= read -r c; do bad "publishes on all interfaces (Docker bypasses ufw): $c"; done <<<"$public"
  fi
  sockets=$(awk -F'|' '$5!="" && !($2=="traefik" && $3=="socket-proxy") {print $1" ("$5")"}' <<<"$containers")
  if [ -z "$sockets" ]; then ok "Docker socket mounted only in socket-proxy"; else
    while IFS= read -r c; do bad "Docker socket mounted (root on the host): $c"; done <<<"$sockets"
  fi
fi

disk=$(fact disk_used)
if [ -n "$disk" ]; then
  if [ "$disk" -lt 85 ]; then note "disk /: ${disk}%"; else note "disk /: ${disk}%, clean up before a rollout"; fi
fi

projects=$(awk -F'|' '$2!="" && $2!="traefik" {print $2}' <<<"$containers" | sort -u | paste -sd, -)
echo "LAYER=$layer FAIL=$FAILS PROJECTS=$projects"
[ "$FAILS" -eq 0 ]
