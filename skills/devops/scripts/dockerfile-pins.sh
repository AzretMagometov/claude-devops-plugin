#!/usr/bin/env bash
# Prints the lines of a Dockerfile that make BuildKit ask a registry on every
# build: a FROM or COPY --from image without @sha256:<digest>, and a
# `# syntax=` line (it pulls the frontend image). FROM scratch and a FROM or
# COPY --from that names an earlier stage (AS <name>, or its index) pass.
# Exit 1 when it prints a line.
#   bash dockerfile-pins.sh [Dockerfile]
set -euo pipefail

FILE=${1:-Dockerfile}
[[ -f $FILE ]] || { echo "dockerfile-pins.sh: no file $FILE" >&2; exit 2; }

awk '
  function pinned(ref) { return ref ~ /@sha256:[0-9a-f]+$/ || ref == "scratch" || (ref in stage) || ref ~ /^[0-9]+$/ }
  function report() { print NR ":" $0; bad = 1 }
  !started && tolower($0) ~ /^#[[:space:]]*syntax[[:space:]]*=/ { report() }
  /^[[:space:]]*[^#[:space:]]/ { started = 1 }
  tolower($1) == "from" {
    i = 2
    while ($i ~ /^--/) i++
    if (!pinned(tolower($i))) report()
    if (tolower($(i + 1)) == "as") stage[tolower($(i + 2))] = 1
  }
  tolower($1) == "copy" {
    for (i = 2; $i ~ /^--/; i++)
      if (tolower($i) ~ /^--from=/ && !pinned(tolower(substr($i, 8)))) report()
  }
  END { exit bad }
' "$FILE"
