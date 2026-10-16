#!/usr/bin/env bash
# Unit tests for assets/deploy-app: argument and command parsing, the lock,
# the image and registry taken from .env, the pre-deploy dump. No Docker
# daemon: a fake `docker` records its arguments and fails, so every run stops
# at the registry login. With FAKE_DOCKER=up the run reaches the dump:
# `docker exec` runs the dump script here with fake psql and pg_dump, and
# `compose up` fails, so the run ends at the rollback. The full rollout is covered by integration_test.sh.
#
# deploy-app writes to /opt/<app> and needs flock(1) from util-linux, so on a
# machine without flock the tests re-run themselves in a debian container.
#   bash deploy-app_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if ! command -v flock >/dev/null || [[ ! -w /opt ]]; then
  exec docker run --rm -v "${HERE%/scripts}:/skill:ro" debian:13 bash /skill/scripts/deploy-app_test.sh
fi

DEPLOY_APP="${HERE%/scripts}/assets/deploy-app"
SHA=0123456789abcdef0123456789abcdef01234567
TMP=$(mktemp -d)
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "docker $*" >> "$DOCKER_CALLS"
[[ ${FAKE_DOCKER:-} == up ]] || exit 1
case "$1" in
  ps) echo pg0 ;;
  exec) shift 2; POSTGRES_USER=u POSTGRES_DB=app exec "$@" ;;
  compose) [[ " $* " != *" up "* ]] ;;
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
FAILED=0

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
unset FAKE_DOCKER FAIL_DB

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
