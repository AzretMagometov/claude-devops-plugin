#!/usr/bin/env bash
# Tests for forge-check.sh without a forge: shims first in PATH stand in for
# curl (Forgejo API) and gh (GitHub). Each shim answers from fixture files:
# the request path, with the limit/page/per_page query cut off, names a file
# in $SHIM/fx (slashes, ?, & and = become _); <file>.code holds the HTTP code
# (default 200); no file answers 404. Page 2 and later answer [].
#
#   forgejo  token ok/missing/bad, repository exists/missing, owner org/user,
#            secrets and variables at repository or owner level, runners
#            online/offline/none/unknown, waiting runs, the image package,
#            required names from the project workflow or the template
#   github   gh logged in or not, organization secrets, hosted and
#            self-hosted runners, the GHCR package
#
#   bash forge-check_test.sh
# shellcheck disable=SC2016  # workflow text and bash -c code stay literal
set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0
mkdir "$T/bin" "$T/fx"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/stdout prev=
for a in "$@"; do
  case $prev in -o) out=$a ;; -H) [[ $a != @* ]] || cat "${a#@}" >> "$SHIM/headers.log" ;; esac
  prev=$a
done
printf '%s\n' "$*" >> "$SHIM/curl-args.log"
[ ! -e "$SHIM/down" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
url=${*: -1}
path=${url#*/api/v1}
page=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<<"$path")
key=$(sed -E 's/[?&]limit=.*$//' <<<"$path" | tr '/?&=' '____')
if [ "${page:-1}" -gt 1 ]; then echo '[]' > "$out"; printf 200
elif [ -f "$SHIM/fx/$key" ]; then cat "$SHIM/fx/$key" > "$out"; cat "$SHIM/fx/$key.code" 2>/dev/null || printf 200
else echo '{"message":"not found"}' > "$out"; printf 404; fi
EOF
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM/gh.log"
[ "$1 $2" != "auth status" ] || exec test -e "$SHIM/gh-auth"
slurp=0 path=
for a in "${@:2}"; do case $a in --slurp) slurp=1 ;; -*) ;; *) path=$a ;; esac; done
key=$(sed -E 's/[?&]per_page=.*$//' <<<"$path" | tr '/?&=' '____')
code=404
[ ! -f "$SHIM/fx/$key" ] || code=$(cat "$SHIM/fx/$key.code" 2>/dev/null || echo 200)
[ "$code" = 200 ] || { echo "gh: Error (HTTP $code)" >&2; exit 1; }
if [ $slurp = 1 ]; then printf '[%s]\n' "$(cat "$SHIM/fx/$key")"; else cat "$SHIM/fx/$key"; fi
EOF
chmod +x "$T/bin/"*

# fx <path> <body> [code]: the answer to one request path.
fx() {
  local k
  k=$(tr '/?&=' '____' <<<"$1")
  printf '%s\n' "$2" > "$T/fx/$k"
  if [ -n "${3:-}" ]; then printf %s "$3" > "$T/fx/$k.code"; else rm -f "$T/fx/$k.code"; fi
}
unfx() { rm -f "$T/fx/$(tr '/?&=' '____' <<<"$1")"; }
names() { local n s=; for n in "$@"; do s="$s${s:+,}{\"name\":\"$n\"}"; done; printf '[%s]' "$s"; }

# The project: a git repository with a controlled remote and workflow.
P=$T/proj
git init -q "$P"
remote() { git -C "$P" remote remove origin 2>/dev/null || true; git -C "$P" remote add origin "$1"; }
workflow() { rm -rf "$P/.forgejo" "$P/.github"; [ "$1" = - ] || { mkdir -p "$P/$1"; cat > "$P/$1/ci.yml"; }; }

FORGEJO_CI='# secrets.COMMENTED is not a reference
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - env:
          REPO_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REGISTRY_TOKEN: ${{ secrets.SHOP_REGISTRY_TOKEN }}
          REGISTRY_USER: ${{ vars.REGISTRY_USER || github.repository_owner }}
          REGISTRY: ${{ vars.REGISTRY }}
  deploy:
    runs-on: [ubuntu-latest]
    steps:
      - env:
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
          DEPLOY_SSH_KEY: ${{secrets.DEPLOY_SSH_KEY}}
          DEPLOY_HOST_KEY: ${{ secrets.DEPLOY_HOST_KEY }}'

# A healthy Forgejo project of organization acme, the token user ops.
forgejo_base() {
  rm -f "$T"/fx/* "$T"/*.log "$T/down" "$P/.devops-config"
  remote https://git.example.com/acme/shop.git
  workflow .forgejo/workflows <<<"$FORGEJO_CI"
  fx /user '{"login":"ops","is_admin":true}'
  fx /repos/acme/shop '{"name":"shop"}'
  fx /orgs/acme '{"username":"acme"}'
  fx /repos/acme/shop/actions/secrets "$(names DEPLOY_HOST DEPLOY_SSH_KEY DEPLOY_HOST_KEY)"
  fx /repos/acme/shop/actions/variables "$(names REGISTRY)"
  fx /orgs/acme/actions/secrets "$(names SHOP_REGISTRY_TOKEN)"
  fx /orgs/acme/actions/variables "$(names REGISTRY_USER)"
  fx '/repos/acme/shop/actions/runs?status=waiting' '{"workflow_runs":[],"total_count":0}'
  fx /admin/actions/runners '[{"id":2,"status":"idle","labels":["self-hosted","ubuntu-latest","linux"]}]'
  fx /orgs/acme/actions/runners '[]'
  fx /repos/acme/shop/actions/runners '[]'
  fx '/packages/acme?type=container&q=shop' "$(names shop-old shop)"
}

# run [env...] [-- args...]: forge-check.sh in the project directory; sets OUT, LAST and RC.
run() {
  local envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ $# -eq 0 ] || { shift; args=("$@"); }
  RC=0
  OUT=$(cd "$P" && env -u FORGEJO_API_TOKEN -u DEVOPS_FORGEJO_TOKEN_CMD -u FORGEJO_URL -u DEVOPS_FORGE \
    -u DEVOPS_REGISTRY_USER PATH="$T/bin:$PATH" SHIM="$T" DEVOPS_CONFIG=/dev/null \
    DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_LOGIN=ops ${envs[@]+"${envs[@]}"} \
    bash "$SKILL/scripts/forge-check.sh" ${args[@]+"${args[@]}"} 2>&1 < /dev/null) || RC=$?
  LAST=$(tail -n1 <<<"$OUT")
}
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else
    echo "FAIL $name (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}
# has KEY=VALUE...: the last line carries each pair exactly.
has() { local kv; for kv in "$@"; do [[ " $LAST " == *" $kv "* ]] || return 1; done; }
ok_line() { [ "$RC" -eq 0 ] && [ "$(grep -c '^FORGE=' <<<"$OUT")" -eq 1 ] && [[ $LAST == FORGE=* ]] && has "$@"; }
# line_is <line>: exit 0 and exactly this last line.
line_is() { [ "$RC" -eq 0 ] && [ "$LAST" = "$1" ]; }
TOK=secret-tok-123

# --- Forgejo ---------------------------------------------------------------
forgejo_base
run FORGEJO_API_TOKEN=$TOK
check "healthy org project: the whole line" line_is "FORGE=forgejo HOST=git.example.com OWNER=acme OWNER_TYPE=org REPO=shop APP=shop IMAGE_REF=git.example.com/acme/shop TOKEN=ok REPO_STATE=exists WORKFLOW=project RUNNER=online RUNS_WAITING=0 SECRETS=DEPLOY_HOST,DEPLOY_HOST_KEY,DEPLOY_SSH_KEY,SHOP_REGISTRY_TOKEN VARS=REGISTRY,REGISTRY_USER MISSING= UNKNOWN= IMAGE=present"
check "the token goes in a header file, never in arguments or output" \
  grep -qx "Authorization: token $TOK" "$T/headers.log"
check "the token is not in curl arguments or output" bash -c '! grep -q "$1" "$2" && [[ $3 != *"$1"* ]]' _ "$TOK" "$T/curl-args.log" "$OUT"
check "human lines in check.sh style" grep -q '^  ok    ' <<<"$OUT"
check "nothing but GET reaches the forge" bash -c '! grep -qE -- "-X|--data|-d " "$1"' _ "$T/curl-args.log"

forgejo_base
fx /orgs/acme/actions/secrets '[]'
run FORGEJO_API_TOKEN=$TOK
check "a secret neither in the repository nor the organization is missing" ok_line MISSING=secrets.SHOP_REGISTRY_TOKEN UNKNOWN=

forgejo_base
fx /orgs/acme/actions/variables '[]'
run FORGEJO_API_TOKEN=$TOK
check "organization owner: REGISTRY_USER with a fallback is still required" ok_line MISSING=vars.REGISTRY_USER

forgejo_base
fx /repos/acme/shop/actions/secrets "$(names DEPLOY_HOST DEPLOY_SSH_KEY DEPLOY_HOST_KEY SHOP_REGISTRY_TOKEN)"
fx /orgs/acme/actions/secrets '[]' 403
run FORGEJO_API_TOKEN=$TOK
check "repository level alone satisfies the names when the owner level is unreadable" ok_line MISSING= UNKNOWN=

forgejo_base
fx /orgs/acme/actions/secrets '[]' 403
run FORGEJO_API_TOKEN=$TOK
check "not in the repository, owner level unreadable: unknown, not missing" ok_line MISSING= UNKNOWN=secrets.SHOP_REGISTRY_TOKEN

forgejo_base
fx /repos/acme/shop '{"message":"not found"}' 404
run FORGEJO_API_TOKEN=$TOK
check "missing repository: repository-level names missing, owner-level ones count" \
  ok_line REPO_STATE=missing RUNS_WAITING=0 SECRETS=SHOP_REGISTRY_TOKEN VARS=REGISTRY_USER \
  MISSING=secrets.DEPLOY_HOST,secrets.DEPLOY_HOST_KEY,secrets.DEPLOY_SSH_KEY,vars.REGISTRY

forgejo_base
run
check "no token: no request sent" [ ! -e "$T/curl-args.log" ]
check "no token: the keys say unknown" ok_line TOKEN=missing REPO_STATE=unknown OWNER_TYPE=unknown RUNNER=unknown \
  RUNS_WAITING=unknown IMAGE=unknown MISSING= \
  UNKNOWN=secrets.DEPLOY_HOST,secrets.DEPLOY_HOST_KEY,secrets.DEPLOY_SSH_KEY,secrets.SHOP_REGISTRY_TOKEN,vars.REGISTRY,vars.REGISTRY_USER

forgejo_base
fx /user '{"message":"token is required"}' 401
run FORGEJO_API_TOKEN=$TOK
check "bad token (401): TOKEN=bad, facts unknown" ok_line TOKEN=bad REPO_STATE=unknown RUNNER=unknown IMAGE=unknown MISSING=

forgejo_base
run "DEVOPS_FORGEJO_TOKEN_CMD=echo $TOK"
check "token from DEVOPS_FORGEJO_TOKEN_CMD" ok_line TOKEN=ok
run DEVOPS_FORGEJO_TOKEN_CMD=false
check "a silent token command: TOKEN=missing" ok_line TOKEN=missing
check "a silent token command: the hint to store the token" grep -q 'store a Forgejo token' <<<"$OUT"

# A user owner equal to the token login: REGISTRY_USER is optional, user
# secrets have no list endpoint.
forgejo_base
remote ssh://git@203.0.113.9:2222/ops/shop.git
fx /repos/ops/shop '{"name":"shop"}'
fx /repos/ops/shop/actions/secrets "$(names DEPLOY_HOST DEPLOY_SSH_KEY DEPLOY_HOST_KEY)"
fx /repos/ops/shop/actions/variables '[]'
fx /user/actions/variables "$(names REGISTRY)"
fx /user/actions/runners '[]'
fx /repos/ops/shop/actions/runners '[]'
fx '/repos/ops/shop/actions/runs?status=waiting' '{"workflow_runs":[{}],"total_count":1}'
fx '/packages/ops?type=container&q=shop' '[]'
run FORGEJO_API_TOKEN=$TOK
check "user owner: variables from /user, secrets unknown, REGISTRY_USER optional" \
  ok_line OWNER=ops OWNER_TYPE=user IMAGE_REF=git.example.com/ops/shop VARS=REGISTRY MISSING= \
  UNKNOWN=secrets.SHOP_REGISTRY_TOKEN RUNS_WAITING=1 IMAGE=absent

forgejo_base
remote https://git.example.com/bob/shop.git
fx /repos/bob/shop '{"name":"shop"}'
fx /repos/bob/shop/actions/secrets "$(names DEPLOY_HOST DEPLOY_SSH_KEY DEPLOY_HOST_KEY SHOP_REGISTRY_TOKEN)"
fx /repos/bob/shop/actions/variables "$(names REGISTRY)"
run FORGEJO_API_TOKEN=$TOK
check "another user as owner: REGISTRY_USER required, owner level unknown" \
  ok_line OWNER_TYPE=user MISSING= UNKNOWN=vars.REGISTRY_USER

forgejo_base
fx /admin/actions/runners '[{"id":2,"status":"offline","labels":["ubuntu-latest"]}]'
run FORGEJO_API_TOKEN=$TOK
check "runner offline" ok_line RUNNER=offline
fx /admin/actions/runners '[{"id":2,"status":"active","labels":["ubuntu-latest:docker://node:20"]}]'
run FORGEJO_API_TOKEN=$TOK
check "runner active (busy) counts as online; label scheme ignored" ok_line RUNNER=online
fx /admin/actions/runners '[]'
run FORGEJO_API_TOKEN=$TOK
check "no runner anywhere" ok_line RUNNER=none
fx /admin/actions/runners '[{"id":3,"status":"idle","labels":["arm64"]}]'
run FORGEJO_API_TOKEN=$TOK
check "an online runner without the workflow label does not count" ok_line RUNNER=none
fx /admin/actions/runners '{"message":"forbidden"}' 403
fx /repos/acme/shop/actions/runners '[{"id":7,"status":"idle","labels":["ubuntu-latest"]}]'
run FORGEJO_API_TOKEN=$TOK
check "no read:admin: a repository runner is found" ok_line RUNNER=online
fx /repos/acme/shop/actions/runners '[]'
run FORGEJO_API_TOKEN=$TOK
check "no read:admin and nothing scoped: unknown" ok_line RUNNER=unknown

forgejo_base
fx '/repos/acme/shop/actions/runs?status=waiting' '{"workflow_runs":[{},{}],"total_count":2}'
run FORGEJO_API_TOKEN=$TOK
check "waiting runs counted" ok_line RUNS_WAITING=2

forgejo_base
fx '/packages/acme?type=container&q=shop' "$(names shop-old)"
run FORGEJO_API_TOKEN=$TOK
check "a package name that only contains the app is not the image" ok_line IMAGE=absent
fx '/packages/acme?type=container&q=shop' '{"message":"forbidden"}' 403
run FORGEJO_API_TOKEN=$TOK
check "packages unreadable: IMAGE=unknown" ok_line IMAGE=unknown

forgejo_base
workflow -
run FORGEJO_API_TOKEN=$TOK
check "no workflow: required names of the Forgejo template" ok_line WORKFLOW=template MISSING=secrets.REGISTRY_TOKEN

forgejo_base
workflow .github/workflows <<<"$FORGEJO_CI"
run FORGEJO_API_TOKEN=$TOK
check "Forgejo reads .github/workflows when .forgejo has none" ok_line WORKFLOW=project MISSING=

forgejo_base
printf '{"app": "shop_v2", "repo": "https://git.example.com/acme/shop"}\n' > "$P/.devops-config"
fx '/packages/acme?type=container&q=shop_v2' "$(names shop_v2)"
run FORGEJO_API_TOKEN=$TOK
check "app from .devops-config, repository name from the remote" ok_line REPO=shop APP=shop_v2 IMAGE_REF=git.example.com/acme/shop_v2 IMAGE=present
fx '/packages/acme?type=container&q=other' "$(names other)"
run FORGEJO_API_TOKEN=$TOK -- . other
check "app from the argument wins" ok_line APP=other IMAGE_REF=git.example.com/acme/other IMAGE=present

forgejo_base
touch "$T/down"
run FORGEJO_API_TOKEN=$TOK
check "forge unreachable: exit 2, no line" bash -c '[ "$1" -eq 2 ] && [[ $2 != *FORGE=* ]]' _ "$RC" "$OUT"

forgejo_base
run -- a b c
check "usage error: exit 2" [ "$RC" -eq 2 ]
run -- "$T/no-such-dir"
check "missing project directory: exit 2" [ "$RC" -eq 2 ]
run DEVOPS_FORGE=gitlab FORGEJO_API_TOKEN=$TOK
check "unknown DEVOPS_FORGE: exit 2" [ "$RC" -eq 2 ]

# --- GitHub ----------------------------------------------------------------
GITHUB_CI='jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - env:
          REGISTRY_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
          DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
          DEPLOY_HOST_KEY: ${{ secrets.DEPLOY_HOST_KEY }}'
github_base() {
  rm -f "$T"/fx/* "$T"/*.log "$T/down" "$P/.devops-config"
  touch "$T/gh-auth"
  remote git@github.com:acme/shop.git
  workflow .github/workflows <<<"$GITHUB_CI"
  fx user '{"login":"ops"}'
  fx repos/acme/shop '{"name":"shop"}'
  fx users/acme '{"login":"acme","type":"Organization"}'
  fx repos/acme/shop/actions/secrets '{"total_count":2,"secrets":[{"name":"DEPLOY_HOST"},{"name":"DEPLOY_SSH_KEY"}]}'
  fx repos/acme/shop/actions/organization-secrets '{"total_count":1,"secrets":[{"name":"DEPLOY_HOST_KEY"}]}'
  fx repos/acme/shop/actions/variables '{"total_count":0,"variables":[]}'
  fx repos/acme/shop/actions/organization-variables '{"message":"forbidden"}' 403
  fx 'repos/acme/shop/actions/runs?status=queued' '{"total_count":1,"workflow_runs":[{}]}'
  fx 'orgs/acme/packages?package_type=container' '[{"name":"shop-old"},{"name":"shop"}]'
}
github_base
run DEVOPS_FORGE=github
check "GitHub org project: the whole line" line_is "FORGE=github HOST=github.com OWNER=acme OWNER_TYPE=org REPO=shop APP=shop IMAGE_REF=ghcr.io/acme/shop TOKEN=ok REPO_STATE=exists WORKFLOW=project RUNNER=hosted RUNS_WAITING=1 SECRETS=DEPLOY_HOST,DEPLOY_HOST_KEY,DEPLOY_SSH_KEY VARS= MISSING= UNKNOWN= IMAGE=present"
check "GitHub: curl is never called" [ ! -e "$T/curl-args.log" ]

github_base
fx repos/acme/shop/actions/organization-secrets '{"message":"forbidden"}' 403
run DEVOPS_FORGE=github
check "GitHub: organization secrets unreadable → unknown" ok_line MISSING= UNKNOWN=secrets.DEPLOY_HOST_KEY

github_base
fx repos/acme/shop/actions/organization-secrets '{"total_count":0,"secrets":[]}'
run DEVOPS_FORGE=github
check "GitHub: a secret nowhere is missing" ok_line MISSING=secrets.DEPLOY_HOST_KEY

github_base
remote https://github.com/ops/shop
fx repos/ops/shop '{"name":"shop"}'
fx users/ops '{"login":"ops","type":"User"}'
fx repos/ops/shop/actions/secrets '{"total_count":2,"secrets":[{"name":"DEPLOY_HOST"},{"name":"DEPLOY_SSH_KEY"}]}'
fx repos/ops/shop/actions/variables '{"total_count":0,"variables":[]}'
fx 'repos/ops/shop/actions/runs?status=queued' '{"total_count":0,"workflow_runs":[]}'
fx 'users/ops/packages?package_type=container' '{"message":"You need at least read:packages scope"}' 403
run DEVOPS_FORGE=github
check "GitHub user owner: no owner-level secrets, so the miss is certain" \
  ok_line OWNER_TYPE=user MISSING=secrets.DEPLOY_HOST_KEY UNKNOWN= IMAGE=unknown

github_base
fx repos/acme/shop '{"message":"Not Found"}' 404
fx orgs/acme/actions/secrets '{"total_count":1,"secrets":[{"name":"DEPLOY_HOST_KEY"}]}'
run DEVOPS_FORGE=github
check "GitHub: missing repository, organization secrets from the organization list" \
  ok_line REPO_STATE=missing MISSING=secrets.DEPLOY_HOST,secrets.DEPLOY_SSH_KEY UNKNOWN=
unfx orgs/acme/actions/secrets
run DEVOPS_FORGE=github
check "GitHub: missing repository, organization list unreadable (admin:org)" \
  ok_line MISSING= UNKNOWN=secrets.DEPLOY_HOST,secrets.DEPLOY_HOST_KEY,secrets.DEPLOY_SSH_KEY

github_base
sed -i.bak 's/runs-on: ubuntu-latest/runs-on: [self-hosted, linux]/' "$P/.github/workflows/ci.yml"
fx orgs/acme/actions/runners '{"total_count":0,"runners":[]}'
fx repos/acme/shop/actions/runners '{"total_count":1,"runners":[{"id":1,"status":"online","labels":[{"name":"self-hosted"},{"name":"linux"}]}]}'
run DEVOPS_FORGE=github
check "GitHub self-hosted runner online" ok_line RUNNER=online
fx repos/acme/shop/actions/runners '{"total_count":1,"runners":[{"id":1,"status":"offline","labels":[{"name":"self-hosted"},{"name":"linux"}]}]}'
run DEVOPS_FORGE=github
check "GitHub self-hosted runner offline" ok_line RUNNER=offline

github_base
rm -f "$T/gh-auth"
run DEVOPS_FORGE=github
check "GitHub: gh not logged in → TOKEN=missing" ok_line TOKEN=missing REPO_STATE=unknown RUNNER=unknown \
  UNKNOWN=secrets.DEPLOY_HOST,secrets.DEPLOY_HOST_KEY,secrets.DEPLOY_SSH_KEY

github_base
fx user '{"message":"Bad credentials"}' 401
run DEVOPS_FORGE=github
check "GitHub: rejected credentials → TOKEN=bad" ok_line TOKEN=bad

if [ "$FAILED" -ne 0 ]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
