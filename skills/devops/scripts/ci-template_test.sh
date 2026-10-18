#!/usr/bin/env bash
# Tests for the `test` job of the Forgejo CI template
# (assets/.forgejo/workflows/ci.yml) without a forge or a runner:
#
#   image    the job image is local/ci-python:3.12-uv<V>, V is the default
#            UV_VERSION of assets/ci-image/Dockerfile; the uv cache volume is
#            the path the runner prerequisites name
#   offline  no step installs git, apt packages or uv
#   sources  the "Fetch the sources" step, run as written, against a local
#            HTTPS server that answers the archive endpoint like Forgejo: the
#            files land in the working directory without the top directory, a
#            rejected token fails the step, a member that escapes the
#            directory fails the step and writes nothing outside
#
#   bash ci-template_test.sh
set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)"
WF=$SKILL/assets/.forgejo/workflows/ci.yml
DOCKERFILE=$SKILL/assets/ci-image/Dockerfile
T=$(mktemp -d)
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT
FAILED=0

check() {
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILED=$((FAILED + 1)); fi
}

# The `test` job of the template, from "  test:" to the next job.
JOB=$(awk '/^  test:$/ {on=1} /^  build:$/ {on=0} on' "$WF")

# --- image -------------------------------------------------------------------
UV_PIN=$(sed -n 's/^ARG UV_VERSION=//p' "$DOCKERFILE" 2>/dev/null || true)
check "Dockerfile pins a uv version" test -n "$UV_PIN"
check "job image is local/ci-python:3.12-uv${UV_PIN}" \
  grep -qxE "      image: local/ci-python:3\.12-uv${UV_PIN//./\\.}" <<<"$JOB"
check "uv cache volume /opt/forgejo-runner/cache/uv:/root/.cache/uv" \
  grep -qxF "        - /opt/forgejo-runner/cache/uv:/root/.cache/uv" <<<"$JOB"
check "Dockerfile base is the application base python:3.12-slim-bookworm" \
  grep -qx "FROM python:3.12-slim-bookworm" "$DOCKERFILE"

# --- offline -----------------------------------------------------------------
STEPS=$(grep -v '^[[:space:]]*#' <<<"$JOB")
no_match() { ! grep -qE "$1" <<<"$STEPS"; }
check "no apt-get in the test job" no_match 'apt-get'
check "no pip install in the test job" no_match 'pip install'
check "no git in the test job" no_match '(^|[[:space:]])git '
check "uv sync --frozen stays" grep -q 'uv sync --frozen' <<<"$STEPS"

# --- sources -----------------------------------------------------------------
# The run: body of the step, dedented, exactly as the runner gets it.
python3 - "$WF" > "$T/fetch.sh" <<'PY'
import re, sys, textwrap
text = open(sys.argv[1]).read()
job = text[text.index("\n  test:\n"):text.index("\n  build:\n")]
step = job[job.index("- name: Fetch the sources"):]
m = re.search(r"^( +)run: \|\n((?:\1 .*\n|\n)+)", step, re.M)
print(textwrap.dedent(m[2]), end="")
PY
check "the step has a run: body" test -s "$T/fetch.sh"

SHA=0123456789abcdef0123456789abcdef01234567
mkdir "$T/srv" "$T/bin"
# The job image calls the interpreter `python`.
ln -s "$(command -v python3)" "$T/bin/python"

# Archives the way Forgejo builds them: one top directory named after the repository.
python3 - "$T/srv" <<'PY'
import io, sys, tarfile
def archive(path, members):
    with tarfile.open(path, "w:gz") as tar:
        for name, kind, data in members:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type, info.mode = tarfile.DIRTYPE, 0o755
                tar.addfile(info)
            elif kind == "sym":
                info.type, info.linkname = tarfile.SYMTYPE, data
                tar.addfile(info)
            else:
                info.size, info.mode = len(data), 0o644
                tar.addfile(info, io.BytesIO(data))
archive(f"{sys.argv[1]}/good.tar.gz", [
    ("app/", "dir", None),
    ("app/pyproject.toml", "file", b"[project]\nname = 'app'\n"),
    ("app/src/", "dir", None),
    ("app/src/main.py", "file", b"print('ok')\n"),
    ("app/main-link.py", "sym", "src/main.py"),
])
archive(f"{sys.argv[1]}/evil.tar.gz", [
    ("app/", "dir", None),
    ("app/ok.txt", "file", b"ok\n"),
    ("app/../../escape.txt", "file", b"escaped\n"),
])
PY

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost \
  -keyout "$T/key.pem" -out "$T/cert.pem" 2>/dev/null

# Forgejo answers 404 to a token without access to the repository.
cat > "$T/server.py" <<'PY'
import http.server, os, ssl, sys
srv_dir, cert, key, port_file = sys.argv[1:5]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        want = f"/api/v1/repos/Owner/app/archive/{os.environ['SHA']}.tar.gz"
        if self.path != want or self.headers.get("Authorization") != "token task-token":
            self.send_error(404)
            return
        body = open(f"{srv_dir}/{os.environ['ARCHIVE']}", "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
httpd = http.server.HTTPServer(("localhost", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
open(port_file, "w").write(str(httpd.server_port))
httpd.serve_forever()
PY

# serve <archive file>: (re)start the server; the port goes to $PORT.
serve() {
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; }
  rm -f "$T/port"
  SHA=$SHA ARCHIVE=$1 python3 "$T/server.py" "$T/srv" "$T/cert.pem" "$T/key.pem" "$T/port" &
  SERVER_PID=$!
  for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
  PORT=$(cat "$T/port")
}

# fetch <workdir> <token>: run the step in an empty directory; prints its output.
fetch() {
  mkdir -p "$1"
  (cd "$1" && env PATH="$T/bin:$PATH" SSL_CERT_FILE="$T/cert.pem" \
    REGISTRY="localhost:$PORT" GITHUB_REPOSITORY=Owner/app GITHUB_SHA=$SHA REPO_TOKEN="$2" \
    bash -euo pipefail "$T/fetch.sh" 2>&1)
}

serve good.tar.gz
out=$(fetch "$T/w1/ws" task-token) || { echo "     | $out"; }
check "good archive: files at the top of the workspace" \
  test -f "$T/w1/ws/pyproject.toml" -a -f "$T/w1/ws/src/main.py"
check "good archive: no top directory left" test ! -e "$T/w1/ws/app"
check "good archive: relative symlink kept" test "$(readlink "$T/w1/ws/main-link.py" 2>/dev/null)" = src/main.py

rc=0
fetch "$T/w2/ws" wrong-token > "$T/w2.out" || rc=$?
check "rejected token: the step fails" test "$rc" -ne 0
check "rejected token: the message names the HTTP error" grep -q '404' "$T/w2.out"

serve evil.tar.gz
rc=0
fetch "$T/w3/ws" task-token > "$T/w3.out" || rc=$?
check "escaping member: the step fails" test "$rc" -ne 0
check "escaping member: nothing written outside the workspace" \
  test ! -e "$T/w3/escape.txt" -a ! -e "$T/escape.txt"

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
