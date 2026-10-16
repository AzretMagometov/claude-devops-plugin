#!/usr/bin/env bash
# Tests for lib/config.sh as the scripts use it: a missing required key stops
# the script before any SSH with the key name and the config path, the file
# gives values, the environment wins over the file, and a symlinked bin
# script still finds the loader. No SSH: every run stops at the config or
# goes through CHECK_FACTS_FILE.
#   bash config_test.sh
set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
NONE=$TMP/no-such-config
KEYS=(DEVOPS_ADMIN DEVOPS_PUBKEY_FILE DEVOPS_IGNOREIP DEVOPS_TZ DEVOPS_ACME_EMAIL DEVOPS_REGISTRY DEVOPS_REGISTRY_USER DEVOPS_FORGE)
CLEAN=(env)
for k in "${KEYS[@]}"; do CLEAN+=(-u "$k"); done

# case_ <name> <expected exit code> <expected output regex> <command...>
# The command runs with every DEVOPS_* key unset; set them in the command.
case_() {
  local name=$1 want_rc=$2 want=$3 out rc=0
  shift 3
  out=$("${CLEAN[@]}" "$@" 2>&1 < /dev/null) || rc=$?
  if [[ $rc -eq $want_rc && $out =~ $want ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), output does not match /$want/"
    printf '%s\n' "$out" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}

missing() { printf 'DEVOPS_%s is not set: add it to %s or set it in the environment' "$1" "$NONE"; }

case_ "vps-init: no DEVOPS_ADMIN"   1 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" "$SKILL/bin/vps-init" 192.0.2.1
case_ "vpn-deploy: no DEVOPS_ADMIN" 1 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" "$SKILL/bin/vpn-deploy" 192.0.2.1 1
case_ "web-init: no DEVOPS_ADMIN"   1 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" "$SKILL/bin/web-init" 192.0.2.1 a@example.com
case_ "web-init: no DEVOPS_ACME_EMAIL and no argument" 1 "$(missing ACME_EMAIL)" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops "$SKILL/bin/web-init" 192.0.2.1
case_ "check.sh: no DEVOPS_ADMIN, exit 2" 2 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" bash "$SKILL/scripts/check.sh" 192.0.2.1
case_ "add-project.sh: no DEVOPS_ADMIN" 1 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" bash "$SKILL/scripts/add-project.sh" 192.0.2.1 demo
case_ "add-project.sh: no DEVOPS_REGISTRY" 1 "$(missing REGISTRY)" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops DEVOPS_REGISTRY_USER=ops bash "$SKILL/scripts/add-project.sh" 192.0.2.1 demo
case_ "add-project.sh: no DEVOPS_REGISTRY_USER" 1 "$(missing REGISTRY_USER)" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops DEVOPS_REGISTRY=git.example.com bash "$SKILL/scripts/add-project.sh" 192.0.2.1 demo
case_ "add-project.sh on github: DEVOPS_REGISTRY not needed, DEVOPS_REGISTRY_USER is" 1 "$(missing REGISTRY_USER)" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops DEVOPS_FORGE=github bash "$SKILL/scripts/add-project.sh" 192.0.2.1 demo
case_ "vps-init: missing public key names DEVOPS_PUBKEY_FILE" 1 "DEVOPS_PUBKEY_FILE" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops DEVOPS_PUBKEY_FILE="$TMP/no.pub" "$SKILL/bin/vps-init" 192.0.2.1

# A symlink in another directory, as in ~/.local/bin, still finds lib/.
mkdir "$TMP/bin"
ln -s "$SKILL/bin/vps-init" "$TMP/bin/vps-init"
case_ "symlinked vps-init finds the loader" 1 "$(missing ADMIN)" DEVOPS_CONFIG="$NONE" "$TMP/bin/vps-init" 192.0.2.1

# The file gives values; the environment wins over it. check.sh asserts
# AllowUsers contains the admin, so the admin it used shows in the result.
printf '%s\n' 'sshd_allowusers=fromfile' hard_conf=1 sshd_permitrootlogin=no sshd_passwordauthentication=no \
  ufw_active=1 ufw_allow=22/tcp f2b_active=1 f2b_sshd=1 web_anchor=0 docker_active=0 vpn_signal= auto_reboot=1 disk_used=1 \
  > "$TMP/facts"
printf '# comment\nDEVOPS_ADMIN=fromfile\n' > "$TMP/env"
case_ "admin from the file" 0 'LAYER=vps FAIL=0' \
  DEVOPS_CONFIG="$TMP/env" CHECK_FACTS_FILE="$TMP/facts" bash "$SKILL/scripts/check.sh" test-host
case_ "environment wins over the file" 1 'AllowUsers contains fromenv' \
  DEVOPS_CONFIG="$TMP/env" DEVOPS_ADMIN=fromenv CHECK_FACTS_FILE="$TMP/facts" bash "$SKILL/scripts/check.sh" test-host

# Defaults of the optional keys, read through the loader itself.
# shellcheck disable=SC2016  # expanded by the inner bash
defaults=$("${CLEAN[@]}" HOME=/home/x DEVOPS_CONFIG="$NONE" bash -c \
  '. "$1/lib/config.sh"; printf "%s|%s|%s|%s\n" "$DEVOPS_PUBKEY_FILE" "$DEVOPS_IGNOREIP" "$DEVOPS_TZ" "$DEVOPS_FORGE"' _ "$SKILL")
if [[ $defaults == "/home/x/.ssh/id_ed25519.pub|||forgejo" ]]; then
  echo "ok   defaults: pubkey ~/.ssh/id_ed25519.pub, ignoreip and tz empty, forge forgejo"
else
  echo "FAIL defaults: got «$defaults»"
  FAILED=$((FAILED + 1))
fi

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
