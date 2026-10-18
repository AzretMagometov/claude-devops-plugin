#!/usr/bin/env bash
# Tests for lib/config.sh as the scripts use it: a missing required key stops
# the script before any SSH with the key name and the config path, the file
# gives values, the environment wins over the file, and a symlinked bin
# script still finds the loader. No SSH: every run stops at the config or
# goes through CHECK_FACTS_FILE.
#   bash config_test.sh
# shellcheck disable=SC2016  # the code given to lib runs in the inner bash
set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
NONE=$TMP/no-such-config
KEYS=(DEVOPS_ADMIN DEVOPS_PUBKEY_FILE DEVOPS_IGNOREIP DEVOPS_TZ DEVOPS_ACME_EMAIL DEVOPS_REGISTRY DEVOPS_REGISTRY_USER
  DEVOPS_REGISTRY_LOGIN DEVOPS_FORGE DEVOPS_FORGEJO_TOKEN_CMD FORGEJO_API_TOKEN)
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
case_ "add-project.sh: no registry login" 1 "$(missing REGISTRY_LOGIN)" \
  DEVOPS_CONFIG="$NONE" DEVOPS_ADMIN=ops DEVOPS_REGISTRY=git.example.com bash "$SKILL/scripts/add-project.sh" 192.0.2.1 demo
case_ "add-project.sh on github: DEVOPS_REGISTRY not needed, the login is" 1 "$(missing REGISTRY_LOGIN)" \
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

# lib <name> <expected output> <bash code> [KEY=value...] [arg...]: the code
# runs in bash with lib/config.sh sourced, no config file, every key unset,
# the KEY=value words in its environment and the args as $1...
lib() {
  local name=$1 want=$2 code=$3 got envs=() args=()
  shift 3
  for a in "$@"; do if [[ $a =~ ^[A-Z_][A-Z0-9_]*= ]]; then envs+=("$a"); else args+=("$a"); fi; done
  # shellcheck disable=SC2016  # expanded by the inner bash
  got=$("${CLEAN[@]}" DEVOPS_CONFIG="$NONE" ${envs[@]+"${envs[@]}"} bash -c '. "$0/lib/config.sh"; '"$code" \
    "$SKILL" ${args[@]+"${args[@]}"} 2>&1 < /dev/null) || true
  if [[ $got == "$want" ]]; then echo "ok   $name"; else
    echo "FAIL $name: got «${got}», want «${want}»"
    FAILED=$((FAILED + 1))
  fi
}

# --- devops_remote_parse: every remote form git accepts -------------------
while read -r url want; do
  lib "parse $url" "${want//|/ }" 'devops_remote_parse "$1"' "$url"
done <<'EOF'
https://git.example.com/acme/site.git git.example.com|acme|site
https://git.example.com/acme/site git.example.com|acme|site
https://git.example.com/acme/site/ git.example.com|acme|site
https://git.example.com/acme/site.git/ git.example.com|acme|site
https://ops:secret@git.example.com:8443/acme/site.git git.example.com|acme|site
http://203.0.113.9:3000/acme/site 203.0.113.9|acme|site
https://example.com/forge/acme/site.git example.com|acme|site
ssh://git@203.0.113.9:2222/acme/shop.git 203.0.113.9|acme|shop
ssh://git@git.example.com/acme/site git.example.com|acme|site
git@git.example.com:acme/site.git git.example.com|acme|site
git@forge:acme/site forge|acme|site
git.example.com:acme/site.git git.example.com|acme|site
https://github.com/Acme/Site.git github.com|Acme|Site
git@github.com:Acme/Site.git github.com|Acme|Site
EOF
for url in "" /srv/git/site.git "https://git.example.com/site" "git@git.example.com:site"; do
  lib "parse «${url}»: not a forge remote, exit 1" "1" 'devops_remote_parse "$1"; echo $?' "$url"
done

# --- devops_repo: remote, then .devops-config repo, then DEVOPS_REGISTRY_USER
P=$TMP/proj
show='devops_repo "$1"; echo "$DEVOPS_REPO_HOST|$DEVOPS_REPO_OWNER|$DEVOPS_REPO_NAME|$DEVOPS_REPO_SOURCE"'
git init -q "$P"
printf '{"app": "site_v2", "repo": "https://git.example.com/old/site.git"}\n' > "$P/.devops-config"
git -C "$P" remote add origin ssh://git@203.0.113.9:2222/acme/shop.git
lib "repo from an IP remote: host is DEVOPS_REGISTRY" "git.example.com|acme|shop|remote" \
  "cd \"\$1\" && devops_repo && echo \"\$DEVOPS_REPO_HOST|\$DEVOPS_REPO_OWNER|\$DEVOPS_REPO_NAME|\$DEVOPS_REPO_SOURCE\"" "$P" DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=ops
lib "repo from a remote, no DEVOPS_REGISTRY: host from the remote" "203.0.113.9|acme|shop|remote" \
  "$show" "$P"
git -C "$P" remote set-url origin git@forge:acme/site
lib "repo from an ssh alias remote: host is DEVOPS_REGISTRY" "git.example.com|acme|site|remote" \
  "$show" "$P" DEVOPS_REGISTRY=git.example.com
git -C "$P" remote set-url origin https://github.com/Acme/Site.git
lib "repo from a GitHub remote: host stays github.com" "github.com|Acme|Site|remote" \
  "$show" "$P" DEVOPS_REGISTRY=git.example.com
git -C "$P" remote remove origin
lib "no remote: .devops-config repo" "git.example.com|old|site|.devops-config" \
  "$show" "$P" DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=ops
rm "$P/.devops-config"
lib "no remote, no .devops-config: DEVOPS_REGISTRY_USER, name unknown" "git.example.com|ops||DEVOPS_REGISTRY_USER" \
  "$show" "$P" DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=ops
lib "github fallback: host github.com" "github.com|Ops||DEVOPS_REGISTRY_USER" \
  "$show" "$P" DEVOPS_FORGE=github DEVOPS_REGISTRY_USER=Ops
lib "nothing known: exit 1, owner empty" "1|" \
  'devops_repo "$1"; echo "$?|$DEVOPS_REPO_OWNER"' "$P"

# --- devops_image: owner from devops_repo, else DEVOPS_REGISTRY_USER --------
lib "image on forgejo: owner from the repo, lower case" "git.example.com/acme/site_v2" \
  'DEVOPS_REPO_OWNER=AcMe; devops_image site_v2' DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=ops
lib "image on forgejo: legacy DEVOPS_REGISTRY_USER only" "git.example.com/ops/demo" \
  'devops_image demo' DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=Ops
lib "image on github: ghcr.io, owner in lower case" "ghcr.io/acme/demo" \
  'DEVOPS_REPO_OWNER=Acme; devops_image demo' DEVOPS_FORGE=github
lib "image without owner: placeholders" "<registry>/<owner>/demo" 'devops_image demo' DEVOPS_REGISTRY=git.example.com

# --- registry login: DEVOPS_REGISTRY_LOGIN, default DEVOPS_REGISTRY_USER ---
lib "login defaults to DEVOPS_REGISTRY_USER" "ops" 'echo "$DEVOPS_REGISTRY_LOGIN"' DEVOPS_REGISTRY_USER=ops
lib "DEVOPS_REGISTRY_LOGIN wins" "bot" 'echo "$DEVOPS_REGISTRY_LOGIN"' DEVOPS_REGISTRY_USER=ops DEVOPS_REGISTRY_LOGIN=bot
printf 'DEVOPS_REGISTRY=git.example.com\nDEVOPS_REGISTRY_USER=ops\n' > "$TMP/legacy"
# shellcheck disable=SC2016  # expanded by the inner bash
legacy=$("${CLEAN[@]}" DEVOPS_CONFIG="$TMP/legacy" bash -c \
  '. "$1/lib/config.sh"; echo "$DEVOPS_REGISTRY_LOGIN $(devops_image demo)"' _ "$SKILL")
if [[ $legacy == "ops git.example.com/ops/demo" ]]; then echo "ok   env file with legacy keys only: login and image"; else
  echo "FAIL env file with legacy keys only: got «${legacy}»"
  FAILED=$((FAILED + 1))
fi
printf 'DEVOPS_REGISTRY_LOGIN=fromfile\nDEVOPS_FORGEJO_TOKEN_CMD="printf fromfile"\n' > "$TMP/new"
# shellcheck disable=SC2016  # expanded by the inner bash
newkeys=$("${CLEAN[@]}" DEVOPS_CONFIG="$TMP/new" DEVOPS_REGISTRY_LOGIN=fromenv DEVOPS_FORGEJO_TOKEN_CMD='printf fromenv' \
  bash -c '. "$1/lib/config.sh"; echo "$DEVOPS_REGISTRY_LOGIN $(devops_forgejo_token)"' _ "$SKILL")
if [[ $newkeys == "fromenv fromenv" ]]; then echo "ok   environment wins over the file for the new keys"; else
  echo "FAIL environment wins over the file for the new keys: got «${newkeys}»"
  FAILED=$((FAILED + 1))
fi

# --- devops_forgejo_token: FORGEJO_API_TOKEN, else DEVOPS_FORGEJO_TOKEN_CMD --
lib "token from FORGEJO_API_TOKEN, the command is not run" "envtok" \
  'devops_forgejo_token' FORGEJO_API_TOKEN=envtok DEVOPS_FORGEJO_TOKEN_CMD='echo ran >&2; printf cmdtok'
lib "token from the command, trailing newline dropped" "cmdtok|" \
  'printf "%s|" "$(devops_forgejo_token)"; devops_forgejo_token | tr -d "[:alnum:]"' DEVOPS_FORGEJO_TOKEN_CMD='echo cmdtok'
store="security add-generic-password -s devops-forgejo -a ops -w"
[[ $(uname) == Darwin ]] || store="secret-tool store --label=devops-forgejo service devops-forgejo account ops"
lib "failing command: exit 1, how to store the token and the scopes" "1" \
  'devops_forgejo_token 2>/dev/null; echo $?' DEVOPS_FORGEJO_TOKEN_CMD='false' DEVOPS_REGISTRY_USER=ops
lib "empty output: exit 1" "1" \
  'devops_forgejo_token 2>/dev/null; echo $?' DEVOPS_FORGEJO_TOKEN_CMD='true' DEVOPS_REGISTRY_USER=ops
# shellcheck disable=SC2016  # expanded by the inner bash
msg=$("${CLEAN[@]}" DEVOPS_CONFIG="$NONE" DEVOPS_FORGEJO_TOKEN_CMD='echo noise >&2; false' DEVOPS_REGISTRY_USER=ops \
  bash -c '. "$1/lib/config.sh"; devops_forgejo_token' _ "$SKILL" 2>&1 >/dev/null || true)
if [[ $(wc -l <<<"$msg" | xargs) == 1 && $msg == *DEVOPS_FORGEJO_TOKEN_CMD* && $msg == *"$store"* \
  && $msg == *write:repository* && $msg == *write:organization* && $msg != *noise* ]]; then
  echo "ok   failing command: one line with the store command and the scopes, its stderr dropped"
else
  echo "FAIL failing command message: «${msg}»"
  FAILED=$((FAILED + 1))
fi
lib "no token, no command: exit 1 without a message" "1|" \
  'm=$(devops_forgejo_token 2>&1); echo "$?|$m"'

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
