#!/usr/bin/env bash
# Unit tests for assets/deploy-app: argument and command parsing, the lock,
# the image and registry taken from .env, the pre-deploy dump, the compose
# policy gate before the rollout and before the rollback. No Docker
# daemon: a fake `docker` records its arguments and fails, so every run stops
# at the registry login. With FAKE_DOCKER=up the run reaches the dump:
# `docker exec` runs the dump script here with fake psql and pg_dump, and
# `compose up` fails, so the run ends at the rollback; a tag listed in
# FAKE_UP_TAGS comes up. `compose config` prints $CONFIGS/<tag>.json, else
# $CONFIGS/default.json, and the real jq checks it. The full rollout is
# covered by integration_test.sh.
#
# deploy-app writes to /opt/<app> and needs flock(1) from util-linux and jq,
# so on a machine without them the tests re-run themselves in a debian
# container, which installs jq first.
#   bash deploy-app_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v flock >/dev/null || ! command -v jq >/dev/null || [[ ! -w /opt ]]; then
  exec docker run --rm -v "${HERE%/scripts}:/skill:ro" debian:13 bash -c \
    'export DEBIAN_FRONTEND=noninteractive && apt-get -qq update && apt-get -qq install -y jq > /dev/null && exec bash /skill/scripts/deploy-app_test.sh'
fi

DEPLOY_APP="${HERE%/scripts}/assets/deploy-app"
SHA=0123456789abcdef0123456789abcdef01234567
TMP=$(mktemp -d)
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "docker $*${IMAGE_TAG:+ [$IMAGE_TAG]}" >> "$DOCKER_CALLS"
[[ ${FAKE_DOCKER:-} == up ]] || exit 1
case "$1" in
  ps) echo pg0 ;;
  exec) shift 2; POSTGRES_USER=u POSTGRES_DB=app exec "$@" ;;
  compose)
    if [[ " $* " == *" config "* ]]; then
      cat "$CONFIGS/$IMAGE_TAG.json" 2>/dev/null || cat "$CONFIGS/default.json"
    elif [[ " $* " == *" up "* ]]; then
      [[ " ${FAKE_UP_TAGS:-} " == *" $IMAGE_TAG "* ]]
    fi ;;
  run) exit 1 ;;
esac
EOF
# The cluster of the fake postgres: databases app and glitchtip. pg_dump
# fails for the database named in FAIL_DB.
cat > "$BIN/psql" <<'EOF'
#!/usr/bin/env bash
echo "psql $*" >> "$DOCKER_CALLS"
printf '%s\n' app glitchtip
EOF
cat > "$BIN/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo "pg_dump $*" >> "$DOCKER_CALLS"
[[ ${*: -1} != "${FAIL_DB:-}" ]] || exit 1
echo "-- dump of ${*: -1}"
EOF
chmod +x "$BIN/docker" "$BIN/psql" "$BIN/pg_dump"
export DOCKER_CALLS="$TMP/docker-calls"
export CONFIGS="$TMP/configs"
mkdir -p "$CONFIGS"
FAILED=0

# config <tag|default> <app service JSON> [top-level JSON merged in]: the
# stack `docker compose config --format json` renders for that tag, in its
# shape: volumes in long syntax, relative sources resolved against
# /opt/demo, top-level names prefixed with the project.
config() {
  jq -n --argjson app "$2" --argjson top "${3:-{\}}" '{
    name: "demo",
    services: {app: $app, postgres: {image: "postgres:18-alpine",
      volumes: [{type: "volume", source: "postgres_data", target: "/var/lib/postgresql", volume: {}}]}},
    networks: {default: {name: "demo_default"}, proxy: {name: "proxy", external: true}},
    volumes: {postgres_data: {name: "demo_postgres_data"}}
  } * $top' > "$CONFIGS/$1.json"
}
CLEAN_APP='{"image": "git.example.com/ops/demo:t", "security_opt": ["no-new-privileges:true"], "networks": {"proxy": null, "backend": null}}'
config default "$CLEAN_APP"

# A project directory as add-project.sh leaves it, with the given .env body.
project() {
  rm -rf "/opt/$1"
  mkdir -p "/opt/$1/state"
  printf '%s\n' "$2" > "/opt/$1/.env"
  : > "/opt/$1/docker-compose.yml"
}
trap 'rm -rf "$TMP" /opt/demo /opt/other' EXIT

# case_ <name> <expected exit code> <expected output regex> <app args...>
# SSH_ORIGINAL_COMMAND comes from the variable CMD.
case_() {
  local name=$1 want_rc=$2 want=$3 out rc=0
  shift 3
  : > "$DOCKER_CALLS"
  out=$(SSH_ORIGINAL_COMMAND="$CMD" PATH="$BIN:$PATH" bash "$DEPLOY_APP" "$@" 2>&1 < /dev/null) || rc=$?
  if [[ $rc -eq $want_rc && $out =~ $want ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), output does not match /$want/"
    printf '%s\n' "$out" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}

# check <name> <command...>: a plain assertion.
check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    FAILED=$((FAILED + 1))
  fi
}

DEMO_ENV=$'IMAGE=git.example.com/ops/demo\nREGISTRY_TOKEN=secret'
project demo "$DEMO_ENV"

CMD="deploy $SHA"
case_ "no app argument"         1 'usage'
case_ "two app arguments"       1 'usage' demo extra
case_ "uppercase app"           1 'project name' Demo
case_ "app with leading dash"   1 'project name' -demo
case_ "app with a slash"        1 'project name' ../etc
case_ "app a/b"                 1 'project name' a/b
case_ "app with a dot"          1 'project name' a.b
case_ "app A"                   1 'project name' A
case_ "app with leading _"      1 'project name' _x
case_ "app with underscores"    1 'no directory /opt/my_app_v4' my_app_v4
case_ "app of 42 characters"    1 'project name' "a$(printf 'b%.0s' {1..41})"
case_ "app of 41 characters"    1 'no directory' "a$(printf 'b%.0s' {1..40})"
case_ "app without a directory" 1 'no directory /opt/nope' nope

CMD=""
case_ "empty command"           1 'expected "deploy <tag>"' demo
for CMD in "ls" "deploy" "deploy ${SHA:0:39}" "deploy ${SHA}0" "deploy ${SHA^^}" \
           "deploy $SHA now" "deploy  $SHA" " deploy $SHA" "deploy $SHA;id" "deploy latest" \
           "rollback $SHA"; do
  case_ "refused: «${CMD}»"       1 'expected "deploy <tag>"' demo
done
check "refused commands never reach docker" test ! -s "$DOCKER_CALLS"
check "refusals are logged to state/deploy.log" \
  grep -q 'expected "deploy <tag>", got: rollback' /opt/demo/state/deploy.log

CMD="deploy $SHA"
case_ "user from the owner of IMAGE" 1 'registry git\.example\.com refused' demo
check "login to the registry of IMAGE as its owner" \
  grep -qx 'docker login git.example.com -u ops --password-stdin' "$DOCKER_CALLS"

project other $'IMAGE="registry.local:5000/team/other"\nREGISTRY_USER=bot\nREGISTRY_TOKEN=x'
case_ "image and user from .env" 1 'registry registry\.local:5000 refused' other
check "login to the registry of IMAGE as REGISTRY_USER" \
  grep -qx 'docker login registry.local:5000 -u bot --password-stdin' "$DOCKER_CALLS"

project other 'REGISTRY_TOKEN=x'
case_ "no IMAGE"                1 'no IMAGE in /opt/other/\.env' other
check "no IMAGE never reaches docker" test ! -s "$DOCKER_CALLS"
project other $'IMAGE=registry.local:5000/other\nREGISTRY_TOKEN=x'
case_ "IMAGE without an owner and no REGISTRY_USER" 1 'no REGISTRY_USER in /opt/other/\.env' other
project other 'IMAGE=registry.local:5000/team/other'
case_ "no REGISTRY_TOKEN"       1 'no REGISTRY_TOKEN' other
rm /opt/other/.env
case_ "no .env"                 1 'cannot read /opt/other/\.env' other

# Another rollout of the same project holds the lock (here: this shell on
# fd 8): refused at once.
exec 8> /opt/demo/state/deploy.lock
flock -n 8
case_ "lock held by another run" 1 'another rollout of demo is running' demo
check "locked run never reaches docker" test ! -s "$DOCKER_CALLS"
# The lock is per project.
project other $'IMAGE=git.example.com/ops/other\nREGISTRY_TOKEN=x'
case_ "other project not locked" 1 'refused the login' other
exec 8>&-
case_ "lock released"           1 'refused the login' demo

# --- pre-deploy dump ------------------------------------------------------
# Every database of the cluster goes into the one file, each after a
# \connect to it, so psql restores the whole file from any database.
project demo "$DEMO_ENV"
export FAKE_DOCKER=up
case_ "dump, then up fails, nothing to roll back to" 1 'no previous tag' demo
dump=$(gunzip -c /opt/demo/state/pre-deploy.sql.gz)
check "databases listed without templates" grep -q '^psql .*NOT datistemplate' "$DOCKER_CALLS"
check "every database dumped after its \\connect" \
  test "$dump" = $'\\connect "app"\n-- dump of app\n\\connect "glitchtip"\n-- dump of glitchtip'
check "pg_dump --clean --if-exists as POSTGRES_USER" \
  grep -qx 'pg_dump --clean --if-exists -U u -d glitchtip' "$DOCKER_CALLS"
check "pre-deploy.sql.gz mode 600" test "$(stat -c %a /opt/demo/state/pre-deploy.sql.gz)" = 600
check "up runs after the dump" grep -q ' up ' "$DOCKER_CALLS"

export FAIL_DB=glitchtip
case_ "a failed dump of any database stops the rollout" 1 'pg_dump failed' demo
check "failed dump: up never runs" test -z "$(grep ' up ' "$DOCKER_CALLS")"
check "failed dump keeps the previous file" \
  test "$(gunzip -c /opt/demo/state/pre-deploy.sql.gz)" = "$dump"
unset FAIL_DB

# --- compose policy -------------------------------------------------------
# A compose with a way to the host is refused before the dump and before any
# container changes. The refusal names the service and the key.
gate_refuses() {
  local name=$1 want=$2
  case_ "policy: $name" 1 "refused by the server policy: .*${want}.*production untouched" demo
  check "policy: $name: no dump, no up" test -z "$(grep -E ' up |^pg_dump' "$DOCKER_CALLS")"
}
refused_app() { config "$SHA" "$(jq -c ". + $1" <<<"$CLEAN_APP")"; }

refused_app '{"privileged": true}';                   gate_refuses "privileged" 'app\.privileged'
refused_app '{"network_mode": "host"}';               gate_refuses "network_mode host" 'app\.network_mode'
refused_app '{"network_mode": "container:other"}';    gate_refuses "network_mode of another container" 'app\.network_mode'
refused_app '{"pid": "host"}';                        gate_refuses "pid host" 'app\.pid'
refused_app '{"ipc": "host"}';                        gate_refuses "ipc host" 'app\.ipc'
refused_app '{"uts": "host"}';                        gate_refuses "uts host" 'app\.uts'
refused_app '{"cgroup": "host"}';                     gate_refuses "cgroup host" 'app\.cgroup'
refused_app '{"userns_mode": "host"}';                gate_refuses "userns_mode host" 'app\.userns_mode'
refused_app '{"cap_add": ["SYS_ADMIN"]}';             gate_refuses "cap_add" 'app\.cap_add'
refused_app '{"devices": [{"source": "/dev/sda", "target": "/dev/sda", "permissions": "rwm"}]}'
gate_refuses "devices" 'app\.devices'
refused_app '{"device_cgroup_rules": ["c *:* rmw"]}';  gate_refuses "device_cgroup_rules" 'app\.device_cgroup_rules'
refused_app '{"security_opt": ["seccomp=unconfined"]}'; gate_refuses "seccomp unconfined" 'app\.security_opt'
refused_app '{"security_opt": ["apparmor:unconfined"]}'; gate_refuses "apparmor unconfined" 'app\.security_opt'
refused_app '{"volumes_from": ["container:other-app-1"]}'; gate_refuses "volumes_from another container" 'app\.volumes_from:container:other-app-1'
refused_app '{"volumes": [{"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock", "bind": {}}]}'
gate_refuses "docker socket" 'app\.volumes:/var/run/docker\.sock'
refused_app '{"volumes": [{"type": "bind", "source": "/etc", "target": "/host-etc", "read_only": true, "bind": {}}]}'
gate_refuses "bind outside /opt/demo" 'app\.volumes:/etc'
refused_app '{"volumes": [{"type": "bind", "source": "/opt/demo-other/data", "target": "/data", "bind": {}}]}'
gate_refuses "bind in a directory that only starts with /opt/demo" 'app\.volumes:/opt/demo-other/data'
# Container root is host root: the project directory itself, rw, would let
# the stack write its own exceptions into compose-policy-allow.
refused_app '{"volumes": [{"type": "bind", "source": "/opt/demo", "target": "/p", "bind": {}}]}'
gate_refuses "bind of /opt/demo itself" 'app\.volumes:/opt/demo'
refused_app '{"volumes": [{"type": "bind", "source": "/opt/demo/compose-policy-allow", "target": "/a", "bind": {}}]}'
gate_refuses "bind of the allow file" 'app\.volumes:/opt/demo/compose-policy-allow'
# A named volume is a host bind in disguise with driver_opts, and another
# project's data under an external or foreign name.
config "$SHA" "$CLEAN_APP" '{"volumes": {"data": {"name": "demo_data", "driver_opts": {"type": "none", "o": "bind", "device": "/"}}}}'
gate_refuses "named volume with driver_opts" 'volumes\.data\.driver_opts'
config "$SHA" "$CLEAN_APP" '{"volumes": {"data": {"name": "demo_data", "driver": "rclone"}}}'
gate_refuses "named volume with a driver" 'volumes\.data\.driver'
config "$SHA" "$CLEAN_APP" '{"volumes": {"data": {"name": "other_postgres_data", "external": true}}}'
gate_refuses "external volume" 'volumes\.data\.external'
config "$SHA" "$CLEAN_APP" '{"volumes": {"data": {"name": "other_postgres_data"}}}'
gate_refuses "volume named after another project" 'volumes\.data\.name'
config "$SHA" "$CLEAN_APP" '{"networks": {"theirs": {"name": "other_backend", "external": true}}}'
gate_refuses "external network other than proxy" 'networks\.theirs\.external'
config "$SHA" "$CLEAN_APP" '{"networks": {"theirs": {"name": "other_backend"}}}'
gate_refuses "network named after another project" 'networks\.theirs\.name'
config "$SHA" "$CLEAN_APP" '{"secrets": {"s": {"name": "demo_s", "file": "/etc/shadow"}}}'
gate_refuses "secret file outside /opt/demo" 'secrets\.s\.file'
config "$SHA" "$CLEAN_APP" '{"configs": {"c": {"name": "demo_c", "file": "/root/.ssh/id_ed25519"}}}'
gate_refuses "config file outside /opt/demo" 'configs\.c\.file'
refused_app '{"privileged": true, "cap_add": ["NET_ADMIN"]}'
gate_refuses "every violation listed" 'app\.privileged, app\.cap_add'

: > "$CONFIGS/$SHA.json"
case_ "policy: a compose that does not render" 1 'compose of [0-9a-f]+ does not render; production untouched' demo

# What stays allowed: binds below /opt/demo, named volumes of the project,
# its own networks and the shared proxy, secrets from /opt/demo.
config "$SHA" "$(jq -c '. + {"volumes": [{"type": "bind", "source": "/opt/demo/uploads", "target": "/u", "bind": {}},
  {"type": "volume", "source": "media", "target": "/m", "volume": {}}, {"type": "tmpfs", "target": "/t"}]}' <<<"$CLEAN_APP")" \
  '{"volumes": {"media": {"name": "demo_media", "driver": "local"}}, "networks": {"backend": {"name": "demo_backend"}},
    "secrets": {"s": {"name": "demo_s", "file": "/opt/demo/secret.txt"}}}'
export FAKE_UP_TAGS=$SHA
case_ "policy: a clean compose deploys" 0 'rollout succeeded' demo
check "clean compose recorded as last known good" test "$(cat /opt/demo/state/last-known-good)" = "$SHA"
unset FAKE_UP_TAGS
rm "$CONFIGS/$SHA.json"

# --- exceptions -----------------------------------------------------------
# Root grants an exception per token, one per line, exactly as the refusal
# prints it. The file must be root's and writable by root alone, or the run
# stops: deployer must not grant itself exceptions.
ALLOW=/opt/demo/compose-policy-allow
rm -f /opt/demo/state/last-known-good
refused_app '{"privileged": true, "volumes": [{"type": "bind", "source": "/srv/shared", "target": "/s", "bind": {}}]}'
printf '%s\n' '# vpn sidecar needs it' '  app.privileged  ' '' 'app.volumes:/srv/shared  # read-only share' > "$ALLOW"
chmod 644 "$ALLOW"
case_ "allow file grants exceptions" 1 'no previous tag' demo
check "allowed compose reaches up" grep -q ' up ' "$DOCKER_CALLS"
printf '%s\n' 'app.privileged' > "$ALLOW"
case_ "allow file grants only what it lists" 1 'refused by the server policy: app\.volumes:/srv/shared;' demo
chmod 664 "$ALLOW"
case_ "group-writable allow file stops the run" 1 'compose-policy-allow .*root' demo
check "group-writable allow file: no up" test -z "$(grep ' up ' "$DOCKER_CALLS")"
chmod 646 "$ALLOW"
case_ "world-writable allow file stops the run" 1 'compose-policy-allow .*root' demo
chmod 644 "$ALLOW"
chown 65534 "$ALLOW"
case_ "allow file not owned by root stops the run" 1 'compose-policy-allow .*root' demo
rm "$ALLOW"
ln -s /opt/demo/state/x "$ALLOW"
case_ "allow file as a symlink stops the run" 1 'compose-policy-allow .*root' demo
rm "$ALLOW"
rm "$CONFIGS/$SHA.json"

# --- rollback policy ------------------------------------------------------
# The previous tag is checked before the rollback too: a stack that fails the
# policy is not brought back, a human decides.
PREV=fedcba9876543210fedcba9876543210fedcba98
echo "$PREV" > /opt/demo/state/last-known-good
export FAKE_UP_TAGS=$PREV
case_ "clean previous tag: rolled back" 1 "rolled back to $PREV" demo
check "rollback brings up the previous tag" grep -q " up .*\[$PREV\]" "$DOCKER_CALLS"
config "$PREV" "$(jq -c '. + {"privileged": true}' <<<"$CLEAN_APP")"
case_ "previous tag fails the policy: no rollback" 1 "previous tag $PREV refused by the server policy: app\.privileged.*needs a human" demo
check "dangerous previous tag never comes up" test -z "$(grep " up .*\[$PREV\]" "$DOCKER_CALLS")"
echo "not-a-tag" > /opt/demo/state/last-known-good
case_ "last-known-good that is not a tag: no rollback" 1 'needs a human' demo
check "invalid previous tag never comes up" test "$(grep -c ' up ' "$DOCKER_CALLS")" = 1
unset FAKE_DOCKER FAKE_UP_TAGS

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
