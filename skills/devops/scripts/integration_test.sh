#!/usr/bin/env bash
# End-to-end test of the web chain and deploy-app on a throwaway Ubuntu
# with systemd and Docker inside a privileged local container:
#
#   vps-init → web-init → add-project.sh → ssh deployer@… "deploy <sha>"
#
# The project is a dummy stack (busybox web with a healthcheck, postgres, a
# one-shot migrate) built inside the server and pushed to a registry with
# htpasswd auth on localhost:5000 there. Checks: first rollout, a second one
# with the pre-deploy dump, a broken healthcheck rolled back to
# last-known-good, refused commands, a concurrent rollout refused by the lock,
# restore of the dump, the compose policy refusing an include of a file
# outside the image (a FIFO: reading it would hang), an image label
# routing a foreign host and a published port, check.sh, idempotent reruns of web-init and add-project,
# add-project refusing names that collide through `_`,
# auto-reboot at 04:00 and its removal on a rerun once a VPN unit shows up.
# vpn-deploy on a fresh server is integration_vpn_test.sh.
#
#   bash integration_test.sh        # ~10 min, needs internet and Docker
set -euo pipefail

NAME=deploy-app-it
APP=demo
# shellcheck source=SCRIPTDIR/integration_lib.sh
. "$(dirname "$0")/integration_lib.sh"
mkdir "$W/app"
# deploy <command>: the CI call, with the deploy key only. The remote command
# is assembled here on purpose, with local values in it.
# shellcheck disable=SC2029
deploy() { ssh -i "$DEPLOY_KEY" "deployer@$HOST" "$1"; }

say "vps-init"
OUT=$("$SKILL/bin/vps-init" "$HOST")
printf '%s\n' "$OUT"
check "vps-init: auto-reboot 04:00 in the summary" grep -q '^✓ .*auto-reboot: 04:00' <<<"$OUT"
check "vps-init without DEVOPS_TZ: zone unchanged" grep -q '^✓ .*TZ: unchanged$' <<<"$OUT"
check "52-auto-reboot: reboot at 04:00" \
  test "$(admin cat /etc/apt/apt.conf.d/52-auto-reboot)" = 'Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";'
say "web-init"
"$SKILL/bin/web-init" "$HOST" it@example.com
say "web-init again"
check "web-init idempotent" grep -q 'no changes' <("$SKILL/bin/web-init" "$HOST" it@example.com)
check "deploy-app root 755 = assets/deploy-app" \
  test "$(admin 'stat -c %U:%a /usr/local/bin/deploy-app; sha256sum < /usr/local/bin/deploy-app' | xargs)" \
    = "root:755 $(shasum -a 256 < "$SKILL/assets/deploy-app" | xargs)"
check "deployer home, .ssh, authorized_keys root 755/755/644" \
  test "$(admin 'stat -c %U:%a /home/deployer /home/deployer/.ssh /home/deployer/.ssh/authorized_keys' | xargs)" \
    = "root:755 root:755 root:644"

# --- registry and images --------------------------------------------------
say "registry with a password and project images"
REG_PW=$(openssl rand -hex 16)
admin "set -e
  mkdir -p /tmp/reg
  docker run --rm --entrypoint htpasswd httpd:2.4-alpine -Bbn ops $REG_PW > /tmp/reg/htpasswd
  docker run -d --name registry --restart unless-stopped -p 127.0.0.1:5000:5000 \
    -v /tmp/reg:/auth:ro -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=it \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null"

cat > "$W/app/docker-compose.yml" <<'EOF'
services:
  migrate:
    image: postgres:18-alpine
    restart: "no"
    environment:
      PGPASSWORD: ${POSTGRES_PASSWORD:?}
    command: ["psql", "-h", "postgres", "-U", "${POSTGRES_USER:?}", "-d", "${POSTGRES_DB:?}", "-v", "ON_ERROR_STOP=1", "-c",
              "CREATE TABLE IF NOT EXISTS deploys (tag text); INSERT INTO deploys VALUES ('${IMAGE_TAG:?}')"]
    depends_on:
      postgres:
        condition: service_healthy
    networks: [backend]
  web:
    image: ${IMAGE:?}:${IMAGE_TAG:?}
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8000/health"]
      interval: 2s
      timeout: 2s
      retries: 3
      start_period: 2s
    networks: [proxy, backend]
  postgres:
    image: postgres:18-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:?}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?}
      POSTGRES_DB: ${POSTGRES_DB:?}
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 2s
      timeout: 2s
      retries: 30
    networks: [backend]
volumes:
  postgres_data:
networks:
  proxy:
    external: true
  backend:
EOF
cat > "$W/app/Dockerfile" <<'EOF'
FROM busybox:1.37
ARG HEALTHY=1
RUN mkdir /www && echo up > /www/index.html && if [ "$HEALTHY" = 1 ]; then echo ok > /www/health; fi
ARG COMPOSE=docker-compose.yml
COPY ${COMPOSE} /app/docker-compose.yml
USER 1000:1000
CMD ["httpd", "-f", "-p", "8000", "-h", "/www"]
EOF
SHA1=$(printf one | shasum | cut -c1-40)
SHA2=$(printf two | shasum | cut -c1-40)
SHA3=$(printf bad | shasum | cut -c1-40)
SHA4=$(printf include | shasum | cut -c1-40)
SHA5=$(printf hijack | shasum | cut -c1-40)
SHA6=$(printf ports | shasum | cut -c1-40)
{ echo 'include: [/opt/x.yml]'; cat "$W/app/docker-compose.yml"; } > "$W/app/include.yml"
awk '{ print } /^  postgres:$/ { print "    ports: [\"5432:5432\"]" }' "$W/app/docker-compose.yml" > "$W/app/ports.yml"
IMAGE=localhost:5000/ops/$APP
tar -C "$W/app" -c . | admin "set -e
  rm -rf /tmp/app && mkdir /tmp/app && tar -x -C /tmp/app
  printf '%s' $REG_PW | docker login localhost:5000 -u ops --password-stdin >/dev/null
  docker build -q -t $IMAGE:$SHA1 /tmp/app >/dev/null
  docker build -q -t $IMAGE:$SHA2 --build-arg HEALTHY=1 --label second=1 /tmp/app >/dev/null
  docker build -q -t $IMAGE:$SHA3 --build-arg HEALTHY=0 /tmp/app >/dev/null
  docker build -q -t $IMAGE:$SHA4 --build-arg COMPOSE=include.yml /tmp/app >/dev/null
  docker build -q -t $IMAGE:$SHA5 --label 'traefik.http.routers.$APP.rule=Host(\`victim.example\`)' /tmp/app >/dev/null
  docker build -q -t $IMAGE:$SHA6 --build-arg COMPOSE=ports.yml /tmp/app >/dev/null
  for t in $SHA1 $SHA2 $SHA3 $SHA4 $SHA5 $SHA6; do docker push -q $IMAGE:\$t >/dev/null; docker image rm $IMAGE:\$t >/dev/null; done
  docker logout localhost:5000 >/dev/null"

# --- add-project.sh -------------------------------------------------------
say "add-project.sh without .env and without a Forgejo token"
OUT=$(bash "$SKILL/scripts/add-project.sh" "$HOST" "$APP")
printf '%s\n' "$OUT"
check "waits for .env and the secrets" grep -qx 'WAIT 2' <<<"$OUT"
DEPLOY_KEY=$(sed -n 's/.*pbcopy < \([^)]*\)).*/\1/p' <<<"$OUT")
check "private key left for a manual paste" test -s "$DEPLOY_KEY"
check "/opt/demo root 755, state deployer 755" \
  test "$(admin "stat -c %U:%a /opt/$APP /opt/$APP/state" | xargs)" = "root:755 deployer:755"
check "authorized_keys line" admin "grep -qx 'restrict,command=\"/usr/local/bin/deploy-app $APP\" ssh-ed25519 [A-Za-z0-9+/=]* $APP-deploy@forgejo' /home/deployer/.ssh/authorized_keys"

say ".env without IMAGE"
printf '%s\n' "REGISTRY_TOKEN=$REG_PW" | admin "sudo install -m 600 /dev/stdin /opt/$APP/.env"
OUT=$(bash "$SKILL/scripts/add-project.sh" "$HOST" "$APP")
check "no IMAGE: waits for it, with the path from the config" \
  grep -q "IMAGE=git.example.com/ops/$APP in /opt/$APP/.env" <<<"$OUT"

say ".env and add-project.sh again"
printf '%s\n' "COMPOSE_PROJECT_NAME=$APP" "IMAGE=$IMAGE" "REGISTRY_TOKEN=$REG_PW" \
  POSTGRES_USER=demo POSTGRES_PASSWORD=demopw POSTGRES_DB=demo \
  | admin "sudo install -m 600 /dev/stdin /opt/$APP/.env"
OUT=$(bash "$SKILL/scripts/add-project.sh" "$HOST" "$APP")
printf '%s\n' "$OUT"
check "rerun: DONE, key kept" grep -qx "DONE $APP@$HOST" <<<"$OUT"
check "rerun: .env fixed to root:deployer 640" test "$(admin "sudo stat -c %U:%G:%a /opt/$APP/.env")" = root:deployer:640
check "rerun: one key line" test "$(admin "grep -c ' $APP-deploy@forgejo\$' /home/deployer/.ssh/authorized_keys")" = 1

say "add-project.sh with FORGEJO_API_TOKEN (fake Forgejo)"
cat > "$W/forgejo.py" <<'EOF'
import http.server, json, os, sys
OUT = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(os.path.join(OUT, self.path.rsplit("/", 1)[1]), "w") as f:
            f.write(self.headers["Authorization"] + "\n" + body.get("data", body.get("value", "")))
        self.send_response(204); self.end_headers()
    do_POST = do_PUT
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"[]")
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
EOF
mkdir "$W/secrets"
FPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$W/forgejo.py" "$W/secrets" "$FPORT" &
PIDS+=($!)
sleep 1
admin "sudo install -d -m 755 /opt/apitest"
before=$(find "$W/tmp" -mindepth 1 | wc -l)
OUT=$(FORGEJO_API_TOKEN=tok FORGEJO_URL="http://127.0.0.1:$FPORT" bash "$SKILL/scripts/add-project.sh" "$HOST" apitest)
printf '%s\n' "$OUT"
check "api: DEPLOY_SSH_KEY is a private key" grep -q 'BEGIN OPENSSH PRIVATE KEY' "$W/secrets/DEPLOY_SSH_KEY"
check "api: token sent" grep -qx 'token tok' "$W/secrets/DEPLOY_SSH_KEY"
check "api: DEPLOY_HOST" test "$(tail -n +2 "$W/secrets/DEPLOY_HOST" | xargs)" = 127.0.0.1
check "api: DEPLOY_HOST_KEY pins the server key" \
  test "$(tail -n +2 "$W/secrets/DEPLOY_HOST_KEY" | xargs)" = "127.0.0.1 $(admin "cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub")"
check "api: variable REGISTRY = DEVOPS_REGISTRY" test "$(tail -n +2 "$W/secrets/REGISTRY")" = git.example.com
check "api: no key left on disk" test "$(find "$W/tmp" -mindepth 1 | wc -l)" -eq "$before"
check "api: asks for REGISTRY_TOKEN and .env" grep -qx 'WAIT 2' <<<"$OUT"

say "add-project.sh: names that collide through _"
# Volume x_data of demo and volume data of demo_x are both demo_x_data.
rc=0; OUT=$(bash "$SKILL/scripts/add-project.sh" "$HOST" ${APP}_x 2>&1) || rc=$?
check "${APP}_x refused while $APP exists" grep -q "project ${APP}_x collides with project $APP on" <<<"$OUT"
check "${APP}_x: no directory created" admin "! test -e /opt/${APP}_x"
admin "sudo install -d -m 755 /opt/apitest_v2 && sudo touch /opt/apitest_v2/.env"
rc=0; OUT=$(bash "$SKILL/scripts/add-project.sh" "$HOST" apitest 2>&1) || rc=$?
check "apitest refused while apitest_v2 exists" grep -q 'project apitest collides with project apitest_v2 on' <<<"$OUT"
admin "sudo rm -rf /opt/apitest_v2"

# --- rollouts -------------------------------------------------------------
lkg() { admin "cat /opt/$APP/state/last-known-good"; }
# up starts every service from its image ID: the tag is the one whose ID the
# container runs.
running_tag() {
  local id t
  id=$(admin "docker inspect -f '{{.Image}}' $APP-web-1")
  for t in $SHA1 $SHA2 $SHA3; do
    [ "$(admin "docker image inspect -f '{{.Id}}' $IMAGE:$t 2>/dev/null")" = "$id" ] && echo "$t"
  done
}
rows() { admin "docker exec $APP-postgres-1 psql -U demo -d demo -tAc 'SELECT count(*) FROM deploys'"; }

say "first rollout $SHA1"
check "first rollout succeeds" deploy "deploy $SHA1"
check "last-known-good = SHA1" test "$(lkg)" = "$SHA1"
check "web runs SHA1" test "$(running_tag)" = "$SHA1"
check "web started from the image ID" test "$(admin "docker inspect -f '{{.Config.Image}}' $APP-web-1" | cut -c1-7)" = sha256:
check "first rollout: dump skipped with a log line" admin "grep -q 'pre-deploy dump skipped' /opt/$APP/state/deploy.log"
check "registry login kept in state/docker" admin "sudo test -f /opt/$APP/state/docker/config.json"

say "second rollout $SHA2"
check "second rollout succeeds" deploy "deploy $SHA2"
check "last-known-good = SHA2" test "$(lkg)" = "$SHA2"
check "pre-deploy.sql.gz deployer 600" test "$(admin "stat -c %U:%a /opt/$APP/state/pre-deploy.sql.gz")" = deployer:600
check "dump holds the table of SHA1" admin "sudo gunzip -c /opt/$APP/state/pre-deploy.sql.gz | grep -q '^$SHA1\$'"
check "dump is --clean" admin "sudo gunzip -c /opt/$APP/state/pre-deploy.sql.gz | grep -q 'DROP TABLE IF EXISTS public.deploys'"

say "broken rollout $SHA3 → rollback"
rc=0; OUT=$(deploy "deploy $SHA3" 2>&1) || rc=$?
printf '%s\n' "$OUT" | tail -n 5
check "broken rollout fails" test "$rc" -ne 0
check "reports the rollback" grep -q "rolled back to $SHA2" <<<"$OUT"
check "last-known-good stays SHA2" test "$(lkg)" = "$SHA2"
check "web runs SHA2 again and is healthy" \
  test "$(running_tag) $(admin "docker inspect -f '{{.State.Health.Status}}' $APP-web-1")" = "$SHA2 healthy"

say "compose policy"
admin "sudo mkfifo -m 644 /opt/x.yml"
# perl alarm: macOS has no timeout(1). A blocked read of the FIFO ends in SIGALRM, rc 142.
rc=0; OUT=$(perl -e 'alarm 120; exec @ARGV' ssh -i "$DEPLOY_KEY" "deployer@$HOST" "deploy $SHA4" 2>&1) || rc=$?
printf '%s\n' "$OUT" | tail -n 1
check "include of a file outside the image refused" grep -q "compose of $SHA4 reads files from the host: include;.*production untouched" <<<"$OUT"
check "include refused without opening the file (no timeout)" test "$rc" = 1
check "include: SHA2 keeps running" test "$(lkg) $(running_tag)" = "$SHA2 $SHA2"
admin "sudo rm /opt/x.yml"
rc=0; OUT=$(deploy "deploy $SHA5" 2>&1) || rc=$?
printf '%s\n' "$OUT" | tail -n 1
check "image label routing a foreign host refused" \
  grep -q "compose of $SHA5 refused by the server policy: web.labels:traefik.http.routers.$APP.rule;.*production untouched" <<<"$OUT"
check "foreign host: SHA2 keeps running" test "$(lkg) $(running_tag)" = "$SHA2 $SHA2"
rc=0; OUT=$(deploy "deploy $SHA6" 2>&1) || rc=$?
printf '%s\n' "$OUT" | tail -n 1
check "published postgres port refused" \
  grep -q "compose of $SHA6 refused by the server policy: postgres.ports:\*:5432:5432/tcp;.*production untouched" <<<"$OUT"
check "published port: nothing listens on 5432" admin "! ss -Hltn 'sport = :5432' | grep -q ."

say "refusals"
for c in "ls" "deploy $SHA2; id" "deploy latest" "deploy  $SHA2" ""; do
  rc=0; OUT=$(deploy "$c" 2>&1) || rc=$?
  check "refused «${c}»" grep -q 'expected "deploy <tag>"' <<<"$OUT"
done
rc=0; OUT=$(ssh -i "$DEPLOY_KEY" -tt "deployer@$HOST" 2>&1) || rc=$?
# restrict refuses the pty, and ssh -tt gives up on the session.
check "pty refused" grep -q 'PTY allocation request failed' <<<"$OUT"

say "concurrent rollout"
n=$(admin "grep -c '  rollout $APP ' /opt/$APP/state/deploy.log")
deploy "deploy $SHA1" > "$W/first.log" 2>&1 &
FIRST=$!
for _ in $(seq 100); do
  [ "$(admin "grep -c '  rollout $APP ' /opt/$APP/state/deploy.log")" -gt "$n" ] && break
  sleep 0.2
done
rc=0; OUT=$(deploy "deploy $SHA2" 2>&1) || rc=$?
check "second concurrent rollout refused by the lock" grep -q "another rollout of $APP is running" <<<"$OUT"
check "first rollout unaffected" wait "$FIRST"
check "last-known-good = SHA1 after the first" test "$(lkg)" = "$SHA1"

say "restore from pre-deploy.sql.gz (the command from migration-patterns.md)"
before=$(rows)
admin "docker exec $APP-postgres-1 psql -U demo -d demo -qc \"INSERT INTO deploys VALUES ('junk')\""
admin "docker stop $APP-web-1 \
  && sudo gunzip -c /opt/$APP/state/pre-deploy.sql.gz \
  | docker exec -i $APP-postgres-1 sh -c 'psql -q -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres'" >/dev/null
check "restore brings back the rows of the dump" test "$(rows)" -eq $((before - 1))
check "rollout after restore" deploy "deploy $SHA1"

say "check.sh"
OUT=$(bash "$SKILL/scripts/check.sh" "$HOST") || true
printf '%s\n' "$OUT" | grep -E 'FAIL|LAYER' || true
check "check.sh: web layer, FAIL=0, demo listed" grep -qE "^LAYER=web FAIL=0 PROJECTS=.*$APP" <<<"$OUT"
check "check.sh: no WARN with auto-reboot on" no_warn "$OUT"

say "legacy project: no IMAGE in .env"
admin "sudo cp -p /opt/$APP/.env /opt/$APP/.env.bak && sudo sed -i '/^IMAGE=/d' /opt/$APP/.env"
rc=0; OUT=$(bash "$SKILL/scripts/check.sh" "$HOST") || rc=$?
check "check.sh: WARN names the app without IMAGE" grep -q "^  WARN  $APP: no IMAGE in /opt/$APP/.env, deploy-app cannot roll out without it: add IMAGE=" <<<"$OUT"
check "check.sh: the IMAGE WARN keeps FAIL=0 and rc 0" test "$(tail -n1 <<<"$OUT" | cut -d' ' -f1,2) $rc" = "LAYER=web FAIL=0 0"
admin "sudo mv /opt/$APP/.env.bak /opt/$APP/.env"

say "VPN node: unit xray.service → no auto-reboot"
admin "printf '[Service]\nExecStart=/bin/true\n' | sudo tee /etc/systemd/system/xray.service >/dev/null && sudo systemctl daemon-reload"
rc=0; OUT=$(bash "$SKILL/scripts/check.sh" "$HOST") || rc=$?
check "check.sh: WARN on VPN with auto-reboot" grep -q '^  WARN  auto-reboot on for a VPN node (systemd:xray.service)' <<<"$OUT"
check "check.sh: the WARN keeps FAIL=0 and rc 0" test "$(tail -n1 <<<"$OUT" | cut -d' ' -f1,2) $rc" = "LAYER=web FAIL=0 0"
OUT=$(DEVOPS_TZ=Asia/Tokyo "$SKILL/bin/vps-init" "$HOST")
check "vps-init with DEVOPS_TZ: zone set" test "$(admin timedatectl show -p Timezone --value)" = Asia/Tokyo
check "vps-init on VPN: skip line names the signal" grep -q '^Auto-reboot skipped: VPN node (systemd:xray.service)' <<<"$OUT"
check "vps-init on VPN: summary says no auto-reboot" grep -q '^✓ .*auto-reboot: off' <<<"$OUT"
check "vps-init on VPN: 52-auto-reboot removed" admin "! test -e /etc/apt/apt.conf.d/52-auto-reboot"
OUT=$(bash "$SKILL/scripts/check.sh" "$HOST") || true
check "check.sh on VPN without auto-reboot: no WARN" no_warn "$OUT"
check "check.sh on VPN without auto-reboot: FAIL=0" grep -q '^LAYER=web FAIL=0 ' <<<"$OUT"

finish
