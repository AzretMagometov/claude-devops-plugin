#!/usr/bin/env bash
# What the forge already holds for a project: repository, token, runner,
# secrets and variables the CI workflow reads, the image in the registry.
# Computed on every run from the forge API, nothing is stored.
#
#   forge-check.sh [project dir] [app]
#
# Repository: devops_repo (lib/config.sh) of the project directory, so the
# git remote first. App: the argument, else "app" in .devops-config, else the
# repository name. DEVOPS_FORGE picks the forge:
#   forgejo  curl with the API token (FORGEJO_API_TOKEN, else the output of
#            DEVOPS_FORGEJO_TOKEN_CMD) in a header file; FORGEJO_URL defaults
#            to https://<host of the repository>
#   github   gh api, as the logged-in gh user
# Only GET requests: the script changes nothing on the forge.
#
# Required names are the secrets.X and vars.X the project workflows read
# (.forgejo/workflows, else .github/workflows on Forgejo; .github/workflows on
# GitHub), else those of the skill's CI template. Not required: the automatic
# GITHUB_TOKEN / FORGEJO_TOKEN / GITEA_TOKEN, and a vars.X with a `||`
# fallback, except vars.REGISTRY_USER on Forgejo when the owner is not the
# registry login (DEVOPS_REGISTRY_LOGIN, else the token user): an
# organization cannot log in to the registry. A name counts as present at the
# repository level or the owner level (organization or user), which every
# repository of the owner inherits. Owner-level lists that the API does not
# give are unknown: Forgejo user secrets (no list endpoint), another user's
# variables, organization lists without owner rights.
#
# Last line of the output, for the caller to parse; values have no spaces,
# lists are comma-separated and sorted:
#   FORGE=<forgejo|github> HOST=<host> OWNER=<owner> OWNER_TYPE=<org|user|unknown>
#   REPO=<name> APP=<app> IMAGE_REF=<image the server pulls, devops_image>
#   TOKEN=<ok|missing|bad> REPO_STATE=<exists|missing|unknown>
#   WORKFLOW=<project|template>
#   RUNNER=<online|offline|none|hosted|unknown> RUNS_WAITING=<n|unknown>
#   SECRETS=<names found> VARS=<names found>
#   MISSING=<secrets.X,vars.Y: required, found nowhere>
#   UNKNOWN=<required, not in the repository, owner level not readable>
#   IMAGE=<present|absent|unknown>
# Every required name is in exactly one of: found (SECRETS/VARS), MISSING,
# UNKNOWN. TOKEN=missing or bad leaves the other facts unknown.
# RUNNER: a runner counts when it carries every label of the runs-on of some
# job. Forgejo status idle or active = online, offline = no contact for over a
# minute. online wins; else an unreadable runner list gives unknown; else
# offline when a matching runner exists, none when there is none. GitHub
# without self-hosted in runs-on = hosted. RUNS_WAITING: Forgejo runs in
# status waiting, GitHub runs in status queued; a steady non-zero count means
# no runner takes the jobs.
# Exit code:
#   0  the last line was printed, whatever it says
#   2  usage error, missing setting, the forge does not answer, or an
#      unexpected answer
set -euo pipefail

f=$0; while [ -L "$f" ]; do t=$(readlink "$f"); case $t in /*) f=$t ;; *) f=$(dirname "$f")/$t ;; esac; done
DEVOPS_DIR=$(cd "$(dirname "$f")/.." && pwd)
# shellcheck source=SCRIPTDIR/../lib/config.sh
. "$DEVOPS_DIR/lib/config.sh"
die() { echo "Error: $*" >&2; exit 2; }
[ $# -le 2 ] || die "usage: $(basename "$0") [project dir] [app]"
DIR=${1:-.}
[ -d "$DIR" ] || die "no directory $DIR"
case $DEVOPS_FORGE in forgejo | github) ;; *) die "DEVOPS_FORGE=$DEVOPS_FORGE: expected forgejo or github" ;; esac
devops_repo "$DIR" || die "no repository owner: no git remote origin in $DIR, no repo in .devops-config, DEVOPS_REGISTRY_USER not set"
OWNER=$DEVOPS_REPO_OWNER HOST=$DEVOPS_REPO_HOST
[ -n "$HOST" ] || die "no forge host: the git remote has none and DEVOPS_REGISTRY is not set"
APP=${2:-}
if [ -z "$APP" ] && [ -f "$DIR/.devops-config" ]; then
  APP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("app") or "")' "$DIR/.devops-config" 2>/dev/null) || APP=""
fi
APP=${APP:-$DEVOPS_REPO_NAME}
[ -n "$APP" ] || die "no app name: pass it as the second argument or set app in .devops-config"
REPO=${DEVOPS_REPO_NAME:-$APP}
IMAGE_REF=$(devops_image "$APP")
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }
# csv: stdin lines → sorted unique comma-separated list.
csv() { { grep -v '^$' || true; } | sort -u | paste -sd, - | tr -d '\n'; }

TMPD=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/forge-check.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
BODY=$TMPD/body
# pj CODE: python over the JSON of the last answer, loaded as d.
pj() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); $1" "$BODY"; }

# --- required names and runner labels from the workflows ------------------
if [ "$DEVOPS_FORGE" = forgejo ]; then WF_DIRS=".forgejo/workflows .github/workflows"; else WF_DIRS=".github/workflows"; fi
WF=""
for d in $WF_DIRS; do
  for w in "$DIR/$d"/*.yml "$DIR/$d"/*.yaml; do [ ! -f "$w" ] || WF="$WF$w"$'\n'; done
  [ -z "$WF" ] || break
done
WORKFLOW=project
[ -n "$WF" ] || { WORKFLOW=template WF="$DEVOPS_DIR/assets/.$DEVOPS_FORGE/workflows/ci.yml"; }
SRC=$(while IFS= read -r w; do [ -z "$w" ] || grep -v '^[[:space:]]*#' "$w" || true; done <<<"$WF")
# One line per job: its runs-on labels, comma-separated; expressions skipped.
LABELS=$(python3 -c '
import re,sys
for m in re.finditer(r"^\s*runs-on:\s*(.+?)\s*$", sys.stdin.read(), re.M):
    ls=[l.strip("\"\x27 ") for l in re.split(r"[,\s]+", m[1].strip("[] "))]
    ls=[l for l in ls if l and "$" not in l and "{" not in l and "}" not in l]
    if ls: print(",".join(ls))
' <<<"$SRC")
# required [registry user too]: the required names, one per line.
required() {
  python3 -c '
import re,sys
auto={"GITHUB_TOKEN","FORGEJO_TOKEN","GITEA_TOKEN"}
req,opt=set(),set()
for m in re.finditer(r"\b(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)(\s*\|\|)?", sys.stdin.read()):
    if m[1]=="secrets" and m[2] in auto: continue
    (opt if m[3] else req).add(m[1]+"."+m[2])
if sys.argv[1]=="1" and "vars.REGISTRY_USER" in opt: req.add("vars.REGISTRY_USER")
print("\n".join(sorted(req)))
' "$1" <<<"$SRC"
}

# --- facts, unknown until the API says otherwise ---------------------------
TOKEN=missing OWNER_TYPE=unknown REPO_STATE=unknown RUNNER=unknown RUNS_WAITING=unknown IMAGE=unknown
API_LOGIN=""
# Name lists and whether each was readable.
REPO_SECRETS="" REPO_VARS="" OWN_SECRETS="" OWN_VARS=""
RS_OK=0 RV_OK=0 OS_OK=0 OV_OK=0
# Runner lines "on|off labels" and whether any runner list was unreadable.
RUNNERS="" RUNNERS_HIDDEN=0

if [ "$DEVOPS_FORGE" = forgejo ]; then
  FORGEJO_URL=${FORGEJO_URL:-https://$HOST}
  API=$FORGEJO_URL/api/v1
  # fj PATH: GET, the code in CODE, the body in $BODY. The token goes in a
  # header file only the user can read: curl arguments show in ps.
  fj() {
    CODE=$(curl -sS -o "$BODY" -w '%{http_code}' -H @"$TMPD/auth" -H 'Accept: application/json' "$API$1") \
      || die "no answer from $FORGEJO_URL ($1)"
  }
  # fj_list PATH CODE: CODE (python over the list d) on every page into LIST;
  # 1 when a page does not answer 200.
  fj_list() {
    local p=1 sep='?' n
    [[ $1 != *\?* ]] || sep='&'
    LIST=""
    while :; do
      fj "$1${sep}limit=50&page=$p"
      [ "$CODE" = 200 ] || return 1
      LIST="$LIST$(pj "$2")"$'\n'
      n=$(pj 'print(len(d))')
      [ "$n" -ge 50 ] || return 0
      p=$((p + 1))
    done
  }
  NAMES='print("\n".join(x["name"] for x in d))'
  RUN='print("\n".join(("on" if x.get("status") in ("idle","active") else "off")+" "+",".join(l.split(":")[0] for l in x.get("labels") or []) for x in d))'
  runners() { if fj_list "$1" "$RUN"; then RUNNERS="$RUNNERS$LIST"; else RUNNERS_HIDDEN=1; fi; }

  tok=""
  if [ -n "${FORGEJO_API_TOKEN:-}" ] || [ -n "${DEVOPS_FORGEJO_TOKEN_CMD:-}" ]; then tok=$(devops_forgejo_token) || tok=""; fi
  if [ -n "$tok" ]; then
    (umask 077 && printf 'Authorization: token %s\n' "$tok" > "$TMPD/auth")
    fj /user
    case $CODE in
      200) TOKEN=ok API_LOGIN=$(pj 'print(d.get("login") or "")') ;;
      401 | 403) TOKEN=bad ;;
      *) die "HTTP $CODE from $API/user" ;;
    esac
  fi
  if [ $TOKEN = ok ]; then
    fj "/repos/$OWNER/$REPO"
    case $CODE in 200) REPO_STATE=exists ;; 404) REPO_STATE=missing ;; esac
    fj "/orgs/$OWNER"
    case $CODE in 200) OWNER_TYPE=org ;; 404) OWNER_TYPE=user ;; esac
    if [ $REPO_STATE = exists ]; then
      ! fj_list "/repos/$OWNER/$REPO/actions/secrets" "$NAMES" || { RS_OK=1 REPO_SECRETS=$LIST; }
      ! fj_list "/repos/$OWNER/$REPO/actions/variables" "$NAMES" || { RV_OK=1 REPO_VARS=$LIST; }
      fj "/repos/$OWNER/$REPO/actions/runs?status=waiting&limit=1"
      [ "$CODE" != 200 ] || RUNS_WAITING=$(pj 'print(d.get("total_count", 0))')
      runners "/repos/$OWNER/$REPO/actions/runners"
    elif [ $REPO_STATE = missing ]; then
      RS_OK=1 RV_OK=1 RUNS_WAITING=0
    fi
    if [ $OWNER_TYPE = org ]; then
      ! fj_list "/orgs/$OWNER/actions/secrets" "$NAMES" || { OS_OK=1 OWN_SECRETS=$LIST; }
      ! fj_list "/orgs/$OWNER/actions/variables" "$NAMES" || { OV_OK=1 OWN_VARS=$LIST; }
      runners "/orgs/$OWNER/actions/runners"
    elif [ $OWNER_TYPE = user ] && [ "$(lower "$OWNER")" = "$(lower "$API_LOGIN")" ]; then
      ! fj_list /user/actions/variables "$NAMES" || { OV_OK=1 OWN_VARS=$LIST; }
      runners /user/actions/runners
    else
      RUNNERS_HIDDEN=1
    fi
    # Instance-wide runners; needs read:admin as a site administrator.
    runners /admin/actions/runners
    if fj_list "/packages/$OWNER?type=container&q=$APP" "$NAMES"; then
      if grep -qixF "$APP" <<<"$LIST"; then IMAGE=present; else IMAGE=absent; fi
    fi
  fi
else
  # gh_get ARGS...: gh api, the code in CODE, the body in $BODY.
  gh_get() {
    if gh api "$@" > "$BODY" 2> "$TMPD/err"; then CODE=200; else
      CODE=$(grep -oE 'HTTP [0-9]{3}' "$TMPD/err" | tail -n1 | cut -d' ' -f2 || true)
      [ -n "$CODE" ] || die "no answer from GitHub: $(cat "$TMPD/err")"
    fi
  }
  # gh_names PATH FIELD: names of every page of PATH, list in .FIELD, into LIST.
  # FIELD empty: each page is the list itself.
  gh_names() {
    local sep='?'
    [[ $1 != *\?* ]] || sep='&'
    gh_get --paginate --slurp "$1${sep}per_page=100"
    [ "$CODE" = 200 ] || return 1
    LIST=$(pj "print(\"\\n\".join(x[\"name\"] for p in d for x in (p[\"$2\"] if \"$2\" else p)))")
  }
  if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then
    gh_get user
    case $CODE in
      200) TOKEN=ok API_LOGIN=$(pj 'print(d.get("login") or "")') ;;
      401 | 403) TOKEN=bad ;;
      *) die "HTTP $CODE from GitHub /user" ;;
    esac
  fi
  if [ $TOKEN = ok ]; then
    gh_get "repos/$OWNER/$REPO"
    case $CODE in 200) REPO_STATE=exists ;; 404) REPO_STATE=missing ;; esac
    gh_get "users/$OWNER"
    if [ "$CODE" = 200 ]; then
      case $(pj 'print(d.get("type") or "")') in Organization) OWNER_TYPE=org ;; User) OWNER_TYPE=user ;; esac
    fi
    if [ $REPO_STATE = exists ]; then
      ! gh_names "repos/$OWNER/$REPO/actions/secrets" secrets || { RS_OK=1 REPO_SECRETS=$LIST; }
      ! gh_names "repos/$OWNER/$REPO/actions/variables" variables || { RV_OK=1 REPO_VARS=$LIST; }
      gh_get "repos/$OWNER/$REPO/actions/runs?status=queued&per_page=1"
      [ "$CODE" != 200 ] || RUNS_WAITING=$(pj 'print(d.get("total_count", 0))')
    elif [ $REPO_STATE = missing ]; then
      RS_OK=1 RV_OK=1 RUNS_WAITING=0
    fi
    if [ $OWNER_TYPE = org ]; then
      # The organization entries this repository may read; without the
      # repository, the organization lists (admin:org).
      if [ $REPO_STATE = exists ]; then base="repos/$OWNER/$REPO/actions/organization-"; else base="orgs/$OWNER/actions/"; fi
      ! gh_names "${base}secrets" secrets || { OS_OK=1 OWN_SECRETS=$LIST; }
      ! gh_names "${base}variables" variables || { OV_OK=1 OWN_VARS=$LIST; }
    elif [ $OWNER_TYPE = user ]; then
      # GitHub has no user-level Actions secrets or variables.
      OS_OK=1 OV_OK=1
    fi
    if grep -q '\(^\|,\)self-hosted\(,\|$\)' <<<"$LABELS"; then
      RUN='print("\n".join(("on" if x.get("status")=="online" else "off")+" "+",".join(l["name"] for l in x.get("labels") or []) for p in d for x in p["runners"]))'
      for path in "repos/$OWNER/$REPO/actions/runners" "orgs/$OWNER/actions/runners"; do
        [ $OWNER_TYPE = org ] || [[ $path != orgs/* ]] || continue
        gh_get --paginate --slurp "$path?per_page=100"
        if [ "$CODE" = 200 ]; then RUNNERS="$RUNNERS$(pj "$RUN")"$'\n'; else RUNNERS_HIDDEN=1; fi
      done
    else
      RUNNER=hosted
    fi
    # The list, not GET of one package: without read:packages that answers
    # 404, the list answers 403.
    [ $OWNER_TYPE = org ] && kind=orgs || kind=users
    if gh_names "$kind/$OWNER/packages?package_type=container" ""; then
      if grep -qixF "$APP" <<<"$LIST"; then IMAGE=present; else IMAGE=absent; fi
    fi
  fi
fi

# --- evaluation -------------------------------------------------------------
if [ $TOKEN = ok ] && [ $RUNNER != hosted ]; then
  on=0 off=0
  while read -r st lb; do
    [ -n "$st" ] || continue
    while IFS= read -r job; do
      [ -n "$job" ] || job=$lb
      ok=1
      for l in ${job//,/ }; do [[ ,$lb, == *,$l,* ]] || ok=0; done
      if [ $ok = 1 ]; then
        if [ "$st" = on ]; then on=1; else off=1; fi
        break
      fi
    done <<<"${LABELS:-}"
  done <<<"$RUNNERS"
  if [ $on = 1 ]; then RUNNER=online
  elif [ $RUNNERS_HIDDEN = 1 ]; then RUNNER=unknown
  elif [ $off = 1 ]; then RUNNER=offline
  else RUNNER=none; fi
fi

LOGIN=${DEVOPS_REGISTRY_LOGIN:-$API_LOGIN}
NEED_RU=0
[ "$DEVOPS_FORGE" != forgejo ] || [ "$(lower "$OWNER")" = "$(lower "$LOGIN")" ] || NEED_RU=1
REQUIRED=$(required $NEED_RU)

[ "$DEVOPS_REPO_SOURCE" = remote ] && FROM="the git remote" || FROM=$DEVOPS_REPO_SOURCE
echo "== $DEVOPS_FORGE $HOST: repository $OWNER/$REPO (from $FROM), app $APP"
ok() { echo "  ok    $1"; }
miss() { echo "  MISS  $1"; }
note() { echo "  info  $1"; }
warn() { echo "  WARN  $1"; }

case $TOKEN in
  ok) ok "API token of $API_LOGIN" ;;
  bad) miss "API token rejected (HTTP 401/403): store a new one" ;;
  missing) if [ "$DEVOPS_FORGE" = github ]; then miss "gh is not logged in: gh auth login"; else miss "no API token: set DEVOPS_FORGEJO_TOKEN_CMD or FORGEJO_API_TOKEN"; fi ;;
esac
case $REPO_STATE in
  exists) ok "repository $OWNER/$REPO exists" ;;
  missing) miss "repository $OWNER/$REPO does not exist" ;;
  unknown) warn "repository $OWNER/$REPO: not known" ;;
esac
case $OWNER_TYPE in org) note "owner $OWNER: organization" ;; user) note "owner $OWNER: user" ;; esac
case $RUNNER in
  online | hosted) ok "runner: $RUNNER" ;;
  offline) miss "runner: offline (no contact for over a minute)" ;;
  none) miss "runner: none with the labels of runs-on" ;;
  unknown) warn "runner: not known" ;;
esac
case $RUNS_WAITING in
  0) ok "no runs waiting for a runner" ;;
  unknown) ;;
  *) warn "$RUNS_WAITING runs waiting for a runner" ;;
esac
req=$(csv <<<"$REQUIRED" | sed 's/,/, /g')
note "required by the $WORKFLOW workflow: ${req:-nothing}"
FOUND_S="" FOUND_V="" MISSING="" UNKNOWN=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  kind=${r%%.*} name=${r#*.}
  if [ "$kind" = secrets ]; then rl=$REPO_SECRETS rok=$RS_OK ol=$OWN_SECRETS ook=$OS_OK; else rl=$REPO_VARS rok=$RV_OK ol=$OWN_VARS ook=$OV_OK; fi
  if grep -qxF "$name" <<<"$rl"; then ok "$r (repository)"
  elif grep -qxF "$name" <<<"$ol"; then ok "$r (owner $OWNER)"
  elif [ "$rok" = 1 ] && [ "$ook" = 1 ]; then miss "$r: neither in the repository nor at the owner"; MISSING="$MISSING$r"$'\n'
  else warn "$r: not known (not in the repository, or the owner level is not readable)"; UNKNOWN="$UNKNOWN$r"$'\n'; fi
done <<<"$REQUIRED"
FOUND_S=$(printf '%s\n%s\n' "$REPO_SECRETS" "$OWN_SECRETS" | csv)
FOUND_V=$(printf '%s\n%s\n' "$REPO_VARS" "$OWN_VARS" | csv)
case $IMAGE in
  present) ok "image $IMAGE_REF in the registry" ;;
  absent) note "image $IMAGE_REF not in the registry yet: the first green CI run on main pushes it" ;;
  unknown) warn "image $IMAGE_REF: not known" ;;
esac

echo "FORGE=$DEVOPS_FORGE HOST=$HOST OWNER=$OWNER OWNER_TYPE=$OWNER_TYPE REPO=$REPO APP=$APP IMAGE_REF=$IMAGE_REF" \
  "TOKEN=$TOKEN REPO_STATE=$REPO_STATE WORKFLOW=$WORKFLOW RUNNER=$RUNNER RUNS_WAITING=$RUNS_WAITING" \
  "SECRETS=$FOUND_S VARS=$FOUND_V MISSING=$(csv <<<"$MISSING") UNKNOWN=$(csv <<<"$UNKNOWN") IMAGE=$IMAGE"
