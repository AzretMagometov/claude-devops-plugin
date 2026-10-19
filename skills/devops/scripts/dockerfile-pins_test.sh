#!/usr/bin/env bash
# Tests for dockerfile-pins.sh on sample Dockerfiles: pinned images, earlier
# stages and scratch pass; a tag without a digest, COPY --from of such an
# image and a `# syntax=` line are printed with their line numbers.
#   bash dockerfile-pins_test.sh
set -euo pipefail

PINS="$(cd "$(dirname "$0")" && pwd)/dockerfile-pins.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0
D=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# pins <name> <want exit> <want output> <Dockerfile text>
pins() {
  local name=$1 want_rc=$2 want_out=$3 rc=0 out
  printf '%s\n' "$4" > "$T/Dockerfile"
  out=$(bash "$PINS" "$T/Dockerfile" 2>&1) || rc=$?
  if [[ $rc -eq $want_rc && $out == "$want_out" ]]; then echo "ok   $name"
  else echo "FAIL $name: exit $rc, output: $out"; FAILED=$((FAILED + 1)); fi
}

pins "pinned stages, earlier stage, scratch" 0 "" "FROM ghcr.io/astral-sh/uv:0.10.4@$D AS uv
FROM --platform=linux/amd64 python:3.12-slim-bookworm@$D AS Build
COPY --from=uv /uv /usr/local/bin/
FROM build AS final
COPY --from=0 /x /x
COPY --from=redis:8-alpine@$D /usr/local/bin/redis-cli /usr/local/bin/
FROM scratch
COPY --from=final /app /app"
pins "tag without a digest" 1 "1:FROM python:3.12-slim-bookworm" "FROM python:3.12-slim-bookworm"
pins "lower-case keyword, digest-free stage" 1 "2:from python:3.12 as base" "# a comment
from python:3.12 as base
FROM base"
pins "COPY --from of a tag" 1 "2:COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/" "FROM python:3.12@$D
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/"
pins "stage named later is not a stage yet" 1 "1:FROM app" "FROM app
FROM python:3.12@$D AS app"
pins "syntax line" 1 "1:# syntax=docker/dockerfile:1" "# syntax=docker/dockerfile:1
FROM python:3.12@$D"
out=$(bash "$PINS" "$T/none" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 2 && $out == "dockerfile-pins.sh: no file $T/none" ]]; then echo "ok   missing file fails"
else echo "FAIL missing file: exit $rc, output: $out"; FAILED=$((FAILED + 1)); fi

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
