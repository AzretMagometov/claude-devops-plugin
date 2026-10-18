#!/usr/bin/env bash
# shellcheck disable=SC2016 # Traefik rules quote hosts in backticks
# Unit tests for assets/deploy-app: argument and command parsing, the lock,
# the image and registry taken from .env, the pre-deploy dump, the compose
# policy gate before the rollout and before the rollback. No Docker
# daemon: a fake `docker` records its arguments and fails, so every run stops
# at the registry login. With FAKE_DOCKER=up the run reaches the dump:
# `docker exec` runs the dump script here with fake psql and pg_dump, and
# `compose up` fails, so the run ends at the rollback; a tag listed in
# FAKE_UP_TAGS comes up. `compose config` prints $CONFIGS/<tag>.json, else
# $CONFIGS/default.json, with @TAG@ replaced by the tag, and the real jq
# checks it. `image inspect` answers the ID id-<tag of the reference>, and
# id-repushed for the app image once `compose pull` of the tag in
# FAKE_REPUSH ran: the registry got a new image under the same tag; asked for labels, it prints
# $CONFIGS/labels-<ID without sha256:>.json, else null. `docker run` of an
# image ID prints the compose file "x-compose-of: <ID>" when FAKE_COMPOSE is
# set and fails otherwise (no compose in the image: /opt/demo/docker-compose.yml
# is used); every compose call appends the compose file it got on stdin to
# $COMPOSE_INPUTS. The raw compose check runs the real python3 and PyYAML.
# The full rollout is covered by integration_test.sh.
#
# deploy-app writes to /opt/<app>, needs flock(1) from util-linux, jq and
# python3 with PyYAML, and the fixtures need root: the allow file must be
# root's, and modes must come from the umask alone (a default ACL on the
# host's /opt, as on GitHub runners, overrides it). So the tests always re-run
# themselves as root in a throwaway debian container, which installs jq and
# python3-yaml first; the skill is mounted read-only, everything the tests
# write stays inside the container.
#   bash deploy-app_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ ${DEPLOY_APP_TEST_CONTAINER:-} != 1 ]]; then
  exec docker run --rm -e DEPLOY_APP_TEST_CONTAINER=1 -v "${HERE%/scripts}:/skill:ro" debian:13 bash -c \
    'export DEBIAN_FRONTEND=noninteractive && apt-get -qq update && apt-get -qq install -y jq python3-yaml > /dev/null && exec bash /skill/scripts/deploy-app_test.sh'
fi

DEPLOY_APP="${HERE%/scripts}/assets/deploy-app"
SHA=0123456789abcdef0123456789abcdef01234567
TMP=$(mktemp -d)
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
stdin=$(cat)
echo "docker $*${IMAGE_TAG:+ [$IMAGE_TAG]}" >> "$DOCKER_CALLS"
[[ ${FAKE_DOCKER:-} == up ]] || exit 1
case "$1" in
  ps) echo pg0 ;;
  exec) shift 2; POSTGRES_USER=u POSTGRES_DB=app exec "$@" ;;
  image)
    ref=${*: -1}
    if [[ $* == *Labels* ]]; then
      cat "$CONFIGS/labels-${ref#sha256:}.json" 2>/dev/null || echo null
    elif [[ -e $DOCKER_CALLS.repushed && $ref == */demo:* ]]; then
      echo sha256:id-repushed
    else
      echo "sha256:id-${ref##*:}"
    fi ;;
  compose)
    printf '%s\n' "$stdin" >> "$COMPOSE_INPUTS"
    if [[ " $* " == *" config "* ]]; then
      { cat "$CONFIGS/$IMAGE_TAG.json" 2>/dev/null || cat "$CONFIGS/default.json"; } | sed "s/@TAG@/$IMAGE_TAG/g"
    elif [[ " $* " == *" pull "* ]]; then
      [[ ${FAKE_REPUSH:-} != "$IMAGE_TAG" ]] || touch "$DOCKER_CALLS.repushed"
    elif [[ " $* " == *" up "* ]]; then
      [[ " ${FAKE_UP_TAGS:-} " == *" $IMAGE_TAG "* ]]
    fi ;;
  run) [[ -n ${FAKE_COMPOSE:-} ]] && echo "x-compose-of: ${*: -2:1}" ;;
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
export DOCKER_CALLS="$TMP/docker-calls" COMPOSE_INPUTS="$TMP/compose-inputs"
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
CLEAN_APP='{"image": "git.example.com/ops/demo:@TAG@", "security_opt": ["no-new-privileges:true"], "networks": {"proxy": null, "backend": null}}'
config default "$CLEAN_APP"

# A project directory as add-project.sh leaves it, with the given .env body.
# docker-compose.yml is the fallback compose of images without one: the raw
# file the YAML check reads (the rendered stack comes from $CONFIGS).
project() {
  rm -rf "/opt/$1"
  mkdir -p "/opt/$1/state"
  printf '%s\n' "$2" > "/opt/$1/.env"
  echo 'services: {}' > "/opt/$1/docker-compose.yml"
}
trap 'rm -rf "$TMP" /opt/demo /opt/other /opt/demo_x /opt/demo-x' EXIT

# case_ <name> <expected exit code> <expected output regex> <app args...>
# SSH_ORIGINAL_COMMAND comes from the variable CMD.
case_() {
  local name=$1 want_rc=$2 want=$3 out rc=0
  shift 3
  : > "$DOCKER_CALLS"
  : > "$COMPOSE_INPUTS"
  rm -f "$DOCKER_CALLS.repushed"
  out=$(SSH_ORIGINAL_COMMAND="$CMD" PATH="$BIN:$PATH" timeout 60 bash "$DEPLOY_APP" "$@" 2>&1 < /dev/null) || rc=$?
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

DEMO_ENV=$'IMAGE=git.example.com/ops/demo\nREGISTRY_TOKEN=secret\nSITE_DOMAIN=demo.example\nALLOWED_HOSTS="www.demo.example, API.demo.example"'
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
# Docker publishes ports past ufw: postgres on *:5432 is on the internet.
# One token per port as compose renders it (ranges come one port each):
# host IP (* = every interface, IPv6 in brackets), published port (* = a
# random one), target/protocol.
port_app() { refused_app "{\"ports\": [$1]}"; }
port_app '{"mode": "ingress", "target": 5432, "published": "5432", "protocol": "tcp"}'
gate_refuses "published port" 'app\.ports:\*:5432:5432/tcp'
port_app '{"mode": "ingress", "host_ip": "127.0.0.1", "target": 80, "published": "8080", "protocol": "tcp"}'
gate_refuses "port on loopback" 'app\.ports:127\.0\.0\.1:8080:80/tcp'
port_app '{"mode": "ingress", "target": 3000, "protocol": "tcp"}'
gate_refuses "port without a published number" 'app\.ports:\*:\*:3000/tcp'
port_app '{"mode": "host", "host_ip": "::1", "target": 53, "published": "53", "protocol": "udp"}'
gate_refuses "udp port on IPv6" 'app\.ports:\[::1\]:53:53/udp'
port_app '{"target": 8000, "published": "8000", "protocol": "tcp"}, {"target": 8001, "published": "8001", "protocol": "tcp"}'
gate_refuses "every port listed" 'app\.ports:\*:8000:8000/tcp, app\.ports:\*:8001:8001/tcp'
# expose publishes nothing.
config "$SHA" "$(jq -c '. + {"expose": ["9000"], "ports": []}' <<<"$CLEAN_APP")"
case_ "expose and empty ports pass" 1 'no previous tag' demo

# A bind is a direct child of /opt/demo: nothing deeper, no `..`. Below a
# direct child a container of the stack writes as host root and can plant a
# symlink that a later rollout would mount; /opt/demo itself is root's 755.
bind_app() { refused_app "{\"volumes\": [{\"type\": \"bind\", \"source\": \"$1\", \"target\": \"/x\", \"bind\": {}}]}"; }
bind_app /opt/demo/uploads/avatars;   gate_refuses "bind deeper than a direct child" 'app\.volumes:/opt/demo/uploads/avatars'
bind_app /opt/demo/../etc;            gate_refuses "bind with .." 'app\.volumes:/opt/demo/\.\./etc'
bind_app /opt/demo/..;                gate_refuses "bind of /opt/demo/.." 'app\.volumes:/opt/demo/\.\.'
bind_app /opt/demo/.;                 gate_refuses "bind of /opt/demo/." 'app\.volumes:/opt/demo/\.'
bind_app /opt/demo/;                  gate_refuses "bind of /opt/demo/" 'app\.volumes:/opt/demo/'
# state/ is deployer's: last-known-good, the registry login, the lock.
bind_app /opt/demo/state;             gate_refuses "bind of state/" 'app\.volumes:/opt/demo/state'
# A direct child that is a symlink on disk mounts its target.
ln -s /etc /opt/demo/link
bind_app /opt/demo/link;              gate_refuses "bind of a symlink" 'app\.volumes:/opt/demo/link'
config "$SHA" "$CLEAN_APP" '{"secrets": {"s": {"name": "demo_s", "file": "/opt/demo/link"}}}'
gate_refuses "secret file that is a symlink" 'secrets\.s\.file'
rm /opt/demo/link
config "$SHA" "$CLEAN_APP" '{"secrets": {"s": {"name": "demo_s", "file": "/opt/demo/keys/s.txt"}}}'
gate_refuses "secret file deeper than a direct child" 'secrets\.s\.file'
config "$SHA" "$CLEAN_APP" '{"configs": {"c": {"name": "demo_c", "file": "/opt/demo/../other/.env"}}}'
gate_refuses "config file with .." 'configs\.c\.file'

# Compose names volumes and networks <app>_<name>: with project demo_x on
# the server, volume x_data of demo is demo_x_data, the name of volume data
# of demo_x.
mkdir /opt/demo_x
config "$SHA" "$CLEAN_APP" '{"volumes": {"x_data": {"name": "demo_x_data"}}}'
gate_refuses "volume named into project demo_x" 'volumes\.x_data\.name'
config "$SHA" "$CLEAN_APP" '{"networks": {"x_backend": {"name": "demo_x_backend"}}}'
gate_refuses "network named into project demo_x" 'networks\.x_backend\.name'
rmdir /opt/demo_x

: > "$CONFIGS/$SHA.json"
case_ "policy: a compose that does not render" 1 'compose of [0-9a-f]+ does not render; production untouched' demo

# What stays allowed: binds of direct children of /opt/demo (a real
# directory too), named volumes of the project, its own networks and the
# shared proxy, secrets from /opt/demo. Volume x_data of demo is demo_x_data,
# fine while no project demo_x exists.
mkdir /opt/demo/media
config "$SHA" "$(jq -c '. + {"volumes": [{"type": "bind", "source": "/opt/demo/uploads", "target": "/u", "bind": {}},
  {"type": "bind", "source": "/opt/demo/media", "target": "/md", "bind": {}},
  {"type": "volume", "source": "media", "target": "/m", "volume": {}}, {"type": "tmpfs", "target": "/t"}]}' <<<"$CLEAN_APP")" \
  '{"volumes": {"media": {"name": "demo_media", "driver": "local"}, "x_data": {"name": "demo_x_data"}}, "networks": {"backend": {"name": "demo_backend"}},
    "secrets": {"s": {"name": "demo_s", "file": "/opt/demo/secret.txt"}}}'
export FAKE_UP_TAGS=$SHA
case_ "policy: a clean compose deploys" 0 'rollout succeeded' demo
check "clean compose recorded as last known good" test "$(cat /opt/demo/state/last-known-good)" = "$SHA"
unset FAKE_UP_TAGS
rmdir /opt/demo/media
rm "$CONFIGS/$SHA.json"

# --- files outside the image ----------------------------------------------
# Compose reads include, extends.file and label_file while it parses, even
# with --no-env-resolution --no-path-resolution --no-interpolate, and would
# inline another project's .env (root:deployer 640, readable by deployer).
# So the raw YAML is checked by PyYAML before the first compose call, and
# build is refused: deploy-app pulls, the image is the only source. The
# targets are FIFOs: a reader would block until the timeout of case_.
rm -f /opt/demo/state/last-known-good
rm -rf /opt/other && mkdir /opt/other
mkfifo /opt/other/x.yml /opt/other/.env
raw() { printf '%s\n' "$1" > /opt/demo/docker-compose.yml; }
raw_refuses() {
  local name=$1 want=$2
  case_ "raw: $name" 1 "compose of [0-9a-f]+ reads files from the host: ${want}; .*production untouched" demo
  check "raw: $name: compose never runs" test -z "$(grep '^docker compose' "$DOCKER_CALLS")"
}
raw $'include:\n  - /opt/other/x.yml\nservices: {}';                    raw_refuses "include" 'include'
raw '{"include": ["/opt/other/x.yml"], "services": {}}';                 raw_refuses "include in flow style" 'include'
raw $'"inc\\x6cude": [/opt/other/x.yml]\nservices: {}';                  raw_refuses "include spelled with an escape" 'include'
raw $'x-i: &i {include: [/opt/other/x.yml]}\n<<: *i\nservices: {}';     raw_refuses "include through a merge key" 'include'
raw $'services:\n  app:\n    image: a\n    extends: {file: /opt/other/x.yml, service: s}'
raw_refuses "extends with a file" 'app\.extends\.file'
raw $'services:\n  app:\n    image: a\n    label_file: /opt/other/.env';    raw_refuses "label_file" 'app\.label_file'
raw $'services:\n  app:\n    build: /opt/other';                          raw_refuses "build" 'app\.build'
raw $'x-b: &b\n  build: {context: .}\nservices:\n  app:\n    <<: *b\n    image: a'
raw_refuses "build through a merge key" 'app\.build'
raw $'services:\n  app:\n    image: a\n    build: .\n    label_file: x\nincludes: x\ninclude: []'
raw_refuses "every raw finding listed" 'include, app\.build, app\.label_file'
# What the YAML check cannot judge the same way compose does is refused.
raw_unparsed() {
  case_ "raw: $1" 1 'compose of [0-9a-f]+ is not one plain YAML mapping.*production untouched' demo
  check "raw: $1: compose never runs" test -z "$(grep '^docker compose' "$DOCKER_CALLS")"
}
raw $'!!binary aW5jbHVkZQ==: [/opt/other/x.yml]\nservices: {}';         raw_unparsed "an explicit tag"
raw $'services: {}\n---\ninclude: [/opt/other/x.yml]';                    raw_unparsed "two documents"
raw $'x-a: a include: [/opt/other/x.yml]\nservices: {}';           raw_unparsed "a unicode line separator"
raw '- services';                                                       raw_unparsed "a list"
raw 'services: [';                                                      raw_unparsed "broken YAML"
check "nothing opened the include targets" test -p /opt/other/x.yml
# extends inside the file reads nothing.
raw $'services:\n  base: {image: a}\n  app:\n    extends: base'
case_ "raw: extends of a service in the same file passes" 1 'no previous tag' demo
raw 'services: {}'
rm -rf /opt/other

# --- what the gate reads from the rendered stack --------------------------
# Rendered with --no-env-resolution: env_file stays a path, checked like a
# bind (compose would inline the file into environment otherwise).
case_ "render keeps env_file paths" 1 'no previous tag' demo
check "config runs with --no-env-resolution" grep -q '^docker compose .* config --format json --no-env-resolution' "$DOCKER_CALLS"
env_app() { refused_app "{\"env_file\": [{\"path\": \"$1\"}]}"; }
env_app /opt/other/.env;        gate_refuses "env_file of another project" 'app\.env_file:/opt/other/\.env'
env_app /opt/demo/../other/.env; gate_refuses "env_file with .." 'app\.env_file:/opt/demo/\.\./other/\.env'
env_app /opt/demo/conf/app.env; gate_refuses "env_file deeper than a direct child" 'app\.env_file:/opt/demo/conf/app\.env'
env_app /opt/demo/state/x.env;  gate_refuses "env_file in state/" 'app\.env_file:/opt/demo/state/x\.env'
ln -s /opt/other/.env /opt/demo/link.env
env_app /opt/demo/link.env;     gate_refuses "env_file that is a symlink" 'app\.env_file:/opt/demo/link\.env'
rm /opt/demo/link.env
refused_app '{"build": {"context": "/opt/demo"}}';     gate_refuses "build in the rendered stack" 'app\.build'
refused_app '{"use_api_socket": true}';               gate_refuses "use_api_socket" 'app\.use_api_socket'
refused_app '{"provider": {"type": "/opt/demo/uploads/x"}}'; gate_refuses "provider" 'app\.provider'
refused_app '{"image": null}';                        gate_refuses "service without an image" 'app\.image'
config "$SHA" "$(jq -c '. + {"env_file": [{"path": "/opt/demo/.env"}, {"path": "/opt/demo/app.env", "required": false}]}' <<<"$CLEAN_APP")"
case_ "env_file of the project passes" 1 'no previous tag' demo
rm "${CONFIGS:?}/$SHA.json"

# --- Traefik labels -------------------------------------------------------
# One Traefik serves every project: a router of demo for another project's
# host takes its traffic and its certificate. Hosts come from SITE_DOMAIN and
# ALLOWED_HOSTS in /opt/demo/.env (root's), names start with demo. Image
# labels count: Docker puts them on the container, where Traefik reads them.
labels_app() { refused_app "{\"labels\": $1}"; }
GOOD_LABELS='{"traefik.enable": "true", "traefik.docker.network": "proxy",
  "traefik.http.routers.demo.rule": "Host(`demo.example`)",
  "traefik.http.routers.demo.entrypoints": "websecure",
  "traefik.http.routers.demo.tls.certresolver": "letsencrypt",
  "traefik.http.routers.demo.service": "demo",
  "traefik.http.routers.demo.middlewares": "demo-strip",
  "traefik.http.routers.demo-api.rule": "Host(\"demo.example\", `api.demo.example`) && PathPrefix(`/a||b`) && Method(`GET`)",
  "traefik.http.routers.demo-api.service": "demo@docker",
  "traefik.http.routers.demo-api.tls.domains[0].main": "demo.example",
  "traefik.http.routers.demo-api.tls.domains[0].sans": "www.demo.example, api.demo.example",
  "traefik.http.routers.demo-www.rule": "Host(`WWW.demo.example`) && Path(`/health`)",
  "traefik.http.middlewares.demo-strip.headers.customResponseHeaders.Server": "",
  "traefik.http.services.demo.loadbalancer.server.port": "8000"}'
traefik_refuses() {
  labels_app "$(jq -c ". + $1" <<<"$GOOD_LABELS")"
  gate_refuses "$2" "$3"
}
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(`other.example`)"}' "Host of another project" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(`demo.example`, `other.example`)"}' "a second Host outside the set" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(`demo.example`) || Host(`other.example`)"}' "||" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "PathPrefix(`/`) && !Host(`demo.example`)"}' "negation" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "PathPrefix(`/`)"}' "PathPrefix without Host" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "HostRegexp(`.+`)"}' "HostRegexp" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(`demo.example`) && HostHeader(`x`)"}' "unknown matcher" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(`demo.example`) && Path(\u0001)"}' "placeholder character" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.demo.rule": "Host(\"demo.ex\\u0061mple\")"}' "escape in a host" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.HTTP.Routers.demo.Rule": "Host(`other.example`)"}' "rule in another case" 'app\.labels:traefik\.http\.routers\.demo\.rule'
traefik_refuses '{"traefik.http.routers.other.rule": "Host(`demo.example`)"}' "router of another name" 'app\.labels:traefik\.http\.routers\.other\.rule'
traefik_refuses '{"traefik.http.routers.demox.rule": "Host(`demo.example`)"}' "router name without a dash" 'app\.labels:traefik\.http\.routers\.demox\.rule'
traefik_refuses '{"traefik.http.routers.demo_x.rule": "Host(`demo.example`)"}' "router name with _" 'app\.labels:traefik\.http\.routers\.demo_x\.rule'
traefik_refuses '{"traefik.http.services.other.loadbalancer.server.port": "80"}' "service of another name" 'app\.labels:traefik\.http\.services\.other\.loadbalancer\.server\.port'
traefik_refuses '{"traefik.http.middlewares.other-auth.basicauth.users": "x"}' "middleware of another name" 'app\.labels:traefik\.http\.middlewares\.other-auth\.basicauth\.users'
traefik_refuses '{"traefik.http.routers.demo.service": "api@internal"}' "router to api@internal" 'app\.labels:traefik\.http\.routers\.demo\.service'
traefik_refuses '{"traefik.http.routers.demo.service": "other"}' "router to another service" 'app\.labels:traefik\.http\.routers\.demo\.service'
traefik_refuses '{"traefik.http.routers.demo.tls.domains[1].main": "other.example"}' "certificate for another host" 'app\.labels:traefik\.http\.routers\.demo\.tls\.domains\[1\]\.main'
traefik_refuses '{"traefik.http.routers.demo.tls.domains[0].sans": "www.demo.example,other.example"}' "certificate SAN for another host" 'app\.labels:traefik\.http\.routers\.demo\.tls\.domains\[0\]\.sans'
traefik_refuses '{"traefik.http.routers.demo-b.entrypoints": "websecure"}' "router without a rule" 'app\.labels:traefik\.http\.routers\.demo-b\.rule'
traefik_refuses '{"traefik.tcp.routers.demo.rule": "HostSNI(`*`)", "traefik.tcp.routers.demo.tls.passthrough": "true"}' "HostSNI *" 'app\.labels:traefik\.tcp\.routers\.demo\.rule'
traefik_refuses '{"traefik.udp.routers.demo.entrypoints": "websecure"}' "udp router" 'app\.labels:traefik\.udp\.routers\.demo\.entrypoints'
traefik_refuses '{"traefik.foo": "1"}' "unknown traefik key" 'app\.labels:traefik\.foo'
labels_app '{"traefik.enable": "true"}'; gate_refuses "enabled without a router" 'app\.labels:traefik\.enable'
mkdir /opt/demo-x
traefik_refuses '{"traefik.http.routers.demo-x-api.rule": "Host(`demo.example`)"}' "router named into project demo-x" 'app\.labels:traefik\.http\.routers\.demo-x-api\.rule'
rmdir /opt/demo-x
# Image labels: the compose is clean, the image routes another host.
labels_app "$GOOD_LABELS"
echo '{"traefik.http.routers.demo-img.rule": "Host(`other.example`)", "maintainer": "x"}' > "$CONFIGS/labels-id-$SHA.json"
gate_refuses "image label with another host" 'app\.labels:traefik\.http\.routers\.demo-img\.rule'
echo '{"traefik.http.routers.demo.rule": "Host(`other.example`)"}' > "$CONFIGS/labels-id-18-alpine.json"
gate_refuses "label of a third-party image" 'postgres\.labels:traefik\.http\.routers\.demo\.rule'
rm "${CONFIGS:?}/labels-id-18-alpine.json"
# A compose label overrides the image label of the same key, as in Docker.
echo '{"traefik.http.routers.demo.rule": "Host(`other.example`)"}' > "$CONFIGS/labels-id-$SHA.json"
export FAKE_UP_TAGS=$SHA
case_ "traefik: clean labels deploy" 0 'rollout succeeded' demo
rm "${CONFIGS:?}/labels-id-$SHA.json"
# Without SITE_DOMAIN and ALLOWED_HOSTS no host is allowed.
project demo $'IMAGE=git.example.com/ops/demo\nREGISTRY_TOKEN=secret'
gate_refuses "no hosts in .env" 'app\.labels:traefik\.http\.routers\.demo\.rule.*SITE_DOMAIN.*ALLOWED_HOSTS'
project demo "$DEMO_ENV"
unset FAKE_UP_TAGS
rm "${CONFIGS:?}/$SHA.json"

# --- the images that start ------------------------------------------------
# up starts every service from the image ID checked above, not from a tag:
# a tag moved by another pull after the check changes nothing.
export FAKE_UP_TAGS=$SHA
case_ "pinned rollout" 0 'rollout succeeded' demo
check "up gets the pin file and never builds" \
  grep -q "^docker compose .* -f - -f /opt/demo/state/compose-pin\.json up .*--pull never --no-build" "$DOCKER_CALLS"
check "every service pinned to its image ID" \
  test "$(jq -c . /opt/demo/state/compose-pin.json)" = "{\"services\":{\"app\":{\"image\":\"sha256:id-$SHA\"},\"postgres\":{\"image\":\"sha256:id-18-alpine\"}}}"
unset FAKE_UP_TAGS
rm -f /opt/demo/state/last-known-good

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
# A port exception covers that port alone.
refused_app '{"ports": [{"host_ip": "127.0.0.1", "target": 80, "published": "8080", "protocol": "tcp"},
  {"host_ip": "127.0.0.1", "target": 81, "published": "8081", "protocol": "tcp"}]}'
printf '%s\n' 'app.ports:127.0.0.1:8080:80/tcp  # local admin' > "$ALLOW"
case_ "port exception covers one port" 1 'refused by the server policy: app\.ports:127\.0\.0\.1:8081:81/tcp;' demo
printf '%s\n' 'app.ports:127.0.0.1:8080:80/tcp' 'app.ports:127.0.0.1:8081:81/tcp' > "$ALLOW"
case_ "port exceptions for every port: allowed" 1 'no previous tag' demo
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

# --- one image, one compose -----------------------------------------------
# The compose that passed the policy is the one compose starts, and the app
# image started is the one it came from: the tag resolves to an image ID
# once, the compose is read once from that ID, and `up` never pulls. A tag
# re-pushed in the registry during `compose pull` (the CI token writes
# there) stops the run before `up`.
APPREF=git.example.com/ops/demo
rm -f /opt/demo/state/last-known-good "$CONFIGS/$PREV.json"
export FAKE_COMPOSE=1
case_ "compose from the image: dump, up fails, nothing to roll back to" 1 'no previous tag' demo
check "compose read from the image ID, never from the tag" \
  grep -qx "docker run --rm --pull never --entrypoint cat sha256:id-$SHA /app/docker-compose.yml" "$DOCKER_CALLS"
check "compose read once" test "$(grep -c '^docker run ' "$DOCKER_CALLS")" = 1
check "every compose call got the compose of that ID" \
  test "$(sort -u "$COMPOSE_INPUTS")" = "x-compose-of: sha256:id-$SHA"
check "up never pulls" test -z "$(grep ' up ' "$DOCKER_CALLS" | grep -v -- ' --pull never ')"

export FAKE_REPUSH=$SHA
case_ "tag re-pushed during compose pull: refused" 1 "${APPREF}:${SHA} changed in the registry during the rollout.*production untouched" demo
check "re-pushed tag: no dump, no up" test -z "$(grep -E ' up |^pg_dump' "$DOCKER_CALLS")"

# Rollback: PREVIOUS is pulled explicitly (the weekly prune may have removed
# it), its compose read once from its ID and checked, and a re-push of
# PREVIOUS during the pull keeps it down.
echo "$PREV" > /opt/demo/state/last-known-good
unset FAKE_REPUSH
export FAKE_UP_TAGS=$PREV
case_ "rollback from the image of PREVIOUS" 1 "rolled back to $PREV" demo
check "rollback pulls PREVIOUS" grep -qx "docker pull --quiet ${APPREF}:${PREV}" "$DOCKER_CALLS"
check "rollback reads the compose of the PREVIOUS ID" \
  grep -qx "docker run --rm --pull never --entrypoint cat sha256:id-$PREV /app/docker-compose.yml" "$DOCKER_CALLS"
check "rollback compose calls got the compose of the PREVIOUS ID" \
  test "$(grep -c "x-compose-of: sha256:id-$PREV" "$COMPOSE_INPUTS")" -ge 3
check "rollback up never pulls" grep -q " up .*--pull never.*\[$PREV\]" "$DOCKER_CALLS"
export FAKE_REPUSH=$PREV
case_ "PREVIOUS re-pushed during its compose pull: no rollback" 1 "${APPREF}:${PREV} changed in the registry.*needs a human" demo
check "re-pushed PREVIOUS never comes up" test -z "$(grep " up .*\[$PREV\]" "$DOCKER_CALLS")"
unset FAKE_COMPOSE FAKE_REPUSH
unset FAKE_DOCKER FAKE_UP_TAGS

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
