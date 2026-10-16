#!/usr/bin/env bash
# Tests for the Alembic `migrate.command` of assets/compose.yml. The command
# is read from the template itself (compose `$$` → `$`) and run against
# SQLite in throwaway Alembic projects:
#   - an empty database is upgraded to head, and a rerun at head does nothing;
#   - a database at a revision the image does not know (it is ahead after a
#     rollback) exits 0 with a log line;
#   - a broken migration and a broken revision graph still exit non-zero.
# Needs Docker: the tests run in a python container with alembic and pyyaml.
#   bash migrate_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ ${MIGRATE_TEST_IN_CONTAINER:-} != 1 ]]; then
  exec docker run --rm -e MIGRATE_TEST_IN_CONTAINER=1 -v "${HERE%/scripts}:/skill:ro" python:3.13-slim \
    sh -c 'pip install --quiet --root-user-action=ignore --disable-pip-version-check alembic pyyaml \
           && bash /skill/scripts/migrate_test.sh'
fi

COMPOSE="${HERE%/scripts}/assets/compose.yml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DB="sqlite:///$TMP/app.db"
FAILED=0

# The command of the migrate service, one argument per line in $TMP/cmd.
python3 - "$COMPOSE" > "$TMP/cmd" <<'EOF'
import sys, yaml
for arg in yaml.safe_load(open(sys.argv[1]))["services"]["migrate"]["command"]:
    print(arg.replace("$$", "$").replace("\n", "\x1f"))
EOF
mapfile -t CMD < "$TMP/cmd"
CMD=("${CMD[@]//$'\x1f'/$'\n'}")

# project <dir> <revision>...: an Alembic project on $DB with the given
# revisions. A revision is id:down_revision:sql.
project() {
  local dir=$TMP/$1 rev id down sql
  shift
  mkdir -p "$dir/versions"
  cat > "$dir/alembic.ini" <<EOF
[alembic]
script_location = $dir
sqlalchemy.url = $DB
EOF
  cat > "$dir/env.py" <<'EOF'
from alembic import context
from sqlalchemy import engine_from_config, pool

with engine_from_config(context.config.get_section(context.config.config_ini_section),
                        poolclass=pool.NullPool).connect() as connection:
    context.configure(connection=connection)
    with context.begin_transaction():
        context.run_migrations()
EOF
  cat > "$dir/script.py.mako" <<'EOF'
EOF
  for rev in "$@"; do
    IFS=: read -r id down sql <<<"$rev"
    [[ -n $down ]] && down="\"$down\"" || down=None
    cat > "$dir/versions/$id.py" <<EOF
from alembic import op

revision = "$id"
down_revision = $down


def upgrade():
    op.execute("$sql")
EOF
  done
}

# run <name> <project> <expected exit code> <expected output regex>
run() {
  local name=$1 dir=$TMP/$2 want_rc=$3 want=$4 out rc=0
  out=$(cd "$dir" && "${CMD[@]}" 2>&1) || rc=$?
  if [[ $rc -eq $want_rc && $out =~ $want ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), output does not match /$want/"
    printf '%s\n' "$out" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}

db_rev() { python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('select version_num from alembic_version').fetchone()[0])" "$TMP/app.db"; }

check() {
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILED=$((FAILED + 1)); fi
}

project new  'r1::CREATE TABLE a (x int)' 'r2:r1:CREATE TABLE b (x int)'
project old  'r1::CREATE TABLE a (x int)'
project bad  'r1::CREATE TABLE a (x int)' 'r2:r1:CREATE TABLE b (x int)' 'r3:r2:CREATE TABLE a (x int)'
project lost 'r1::CREATE TABLE a (x int)' 'r2:r1:CREATE TABLE b (x int)' 'r4:r3:CREATE TABLE d (x int)'

run "empty database upgraded to head"     new  0 ''
check "database at r2" test "$(db_rev)" = r2
run "rerun at head does nothing"          new  0 '^$|INFO'
run "database ahead of the image: exit 0" old  0 "locate revision identified by .r2.*newer than this image"
check "database ahead stays at r2" test "$(db_rev)" = r2
run "broken migration fails"              bad  1 'already exists'
check "failed migration leaves r2" test "$(db_rev)" = r2
run "revision graph with a lost parent fails" lost 1 "r3"

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
