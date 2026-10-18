#!/usr/bin/env bash
# Tests for add-project.sh on both forges without a server or a forge: shims
# first in PATH stand in for ssh (the server state comes from a file), gh and
# curl (they log their calls and save the secret values).
#
#   DEVOPS_FORGE=github  secrets through `gh secret set` when gh is logged in,
#                        otherwise the exact commands in the WAIT block;
#                        the .env items name ghcr.io and read:packages
#   forgejo (default)    secrets and the REGISTRY variable through the
#                        Forgejo API with FORGEJO_API_TOKEN or the output of
#                        DEVOPS_FORGEJO_TOKEN_CMD, otherwise a WAIT item; gh
#                        is never called
#   owner and repository come from the git remote of the project directory
#   (the run's working directory), then DEVOPS_REGISTRY_USER and the app name
#
#   bash add-project_test.sh
set -euo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAILED=0
mkdir "$T/bin" "$T/tmp"

# ssh: the facts call prints $T/state, `-G` prints the hostname, the
# authorized_keys call saves the line it would install.
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM/ssh.log"
case "$*" in
  *" -G "*|"-G "*) echo "hostname 203.0.113.5" ;;
  *"LINE="*) cat > /dev/null; printf '%s\n' "$*" >> "$SHIM/ak.log" ;;
  *) cat > /dev/null; cat "$SHIM/state" ;;
esac
EOF
# gh: `auth status` succeeds when $SHIM/auth-ok exists; `secret set NAME`
# saves stdin to $SHIM/gh-NAME.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM/gh.log"
case "$1 $2" in
  "auth status") test -e "$SHIM/auth-ok" ;;
  "secret set") cat > "$SHIM/gh-$3" ;;
  *) exit 1 ;;
esac
EOF
# curl: a GET of organization secrets answers $SHIM/org-secrets when it
# exists, any other GET an empty list; a PUT or POST saves its body to
# $SHIM/api-<last URL segment>; the arguments go to curl-args.log, the
# contents of a header file (-H @file) to curl-headers.log.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET prev=
for a in "$@"; do
  case $prev in -X) method=$a ;; -H) [[ $a != @* ]] || cat "${a#@}" >> "$SHIM/curl-headers.log" ;; esac
  prev=$a
done
url=${*: -1}
printf '%s\n' "$*" >> "$SHIM/curl-args.log"
printf '%s %s\n' "$method" "$url" >> "$SHIM/curl.log"
if [ "$method" = GET ]; then
  case $url in */orgs/*/actions/secrets) cat "$SHIM/org-secrets" 2>/dev/null || echo '[]' ;; *) echo '[]' ;; esac
else cat > "$SHIM/api-${url##*/}"; fi
EOF
chmod +x "$T/bin/"*

# state <key=value...>: the facts the server reports.
state() { printf '%s\n' web=1 "$@" "host_key=ssh-ed25519 AAAAhostkey" > "$T/state"; }
reset() { rm -f "$T"/*.log "$T"/gh-DEPLOY_* "$T"/api-* "$T"/org-secrets; }

# The project directory: a git repository, so the checkout of this plugin
# never lends its own remote. remote URL sets origin, remote - removes it.
git init -q "$T/proj"
remote() {
  git -C "$T/proj" remote remove origin 2>/dev/null || true
  [[ $1 == - ]] || git -C "$T/proj" remote add origin "$1"
}

# run <env...>: add-project.sh demo-host $NAME (default demo) in the project
# directory with the shims; sets OUT and RC.
NAME=demo
run() {
  RC=0
  OUT=$(cd "$T/proj" && env -u FORGEJO_API_TOKEN -u GITHUB_REPO -u FORGEJO_REPO -u DEVOPS_REGISTRY_LOGIN \
    -u DEVOPS_FORGEJO_TOKEN_CMD PATH="$T/bin:$PATH" TMPDIR="$T/tmp" SHIM="$T" \
    DEVOPS_CONFIG=/dev/null DEVOPS_ADMIN=ops DEVOPS_REGISTRY=git.example.com DEVOPS_REGISTRY_USER=Ops \
    "$@" bash "$SKILL/scripts/add-project.sh" demo-host "$NAME" 2>&1 < /dev/null) || RC=$?
}
check() {
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else
    echo "FAIL $name"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
    FAILED=$((FAILED + 1))
  fi
}
# has TEXT...: every TEXT is in OUT; lacks TEXT: it is not, any case.
has() { local t; for t in "$@"; do grep -qF -- "$t" <<<"$OUT" || return 1; done; }
lacks() { ! grep -qiF -- "$1" <<<"$OUT"; }
# logged FILE LINE...: every LINE is a whole line of FILE.
logged() { local f=$1 l; shift; for l in "$@"; do grep -qxF -- "$l" "$f" || return 1; done; }
no_key_left() { [ -z "$(find "$T/tmp" -mindepth 1)" ]; }

ALL=(env=1 registry_token=1 image=1 registry_user=1 key=0)
remote -

# --- github ---------------------------------------------------------------
reset; state "${ALL[@]}"; touch "$T/auth-ok"
run DEVOPS_FORGE=github
check "github + gh: DONE" grep -qx 'DONE demo@demo-host' <<<"$OUT"
check "github + gh: secrets set in Ops/demo" \
  test "$(grep -c -- '^secret set DEPLOY_[A-Z_]* --repo Ops/demo$' "$T/gh.log")" = 3
check "github + gh: DEPLOY_SSH_KEY is a private key" grep -q 'BEGIN OPENSSH PRIVATE KEY' "$T/gh-DEPLOY_SSH_KEY"
check "github + gh: DEPLOY_HOST" test "$(cat "$T/gh-DEPLOY_HOST")" = 203.0.113.5
check "github + gh: DEPLOY_HOST_KEY pins the server key" \
  test "$(cat "$T/gh-DEPLOY_HOST_KEY")" = "203.0.113.5 ssh-ed25519 AAAAhostkey"
check "github + gh: no key left on disk" no_key_left
check "github: key comment demo-deploy@github" grep -q 'demo-deploy@github' "$T/ak.log"
check "github: no Forgejo API call" test ! -e "$T/curl.log"

reset; rm -f "$T/auth-ok"; state "${ALL[@]}"
run DEVOPS_FORGE=github GITHUB_REPO=acme/site
check "github, gh not logged in: WAIT 1" grep -qx 'WAIT 1' <<<"$OUT"
check "github, gh not logged in: the three commands for GITHUB_REPO" \
  has "gh secret set DEPLOY_SSH_KEY --repo acme/site" "gh secret set DEPLOY_HOST --repo acme/site" \
    "gh secret set DEPLOY_HOST_KEY --repo acme/site"
check "github, gh not logged in: no secret sent" logged "$T/gh.log" "auth status"
check "github, gh not logged in: gh called once" test "$(wc -l < "$T/gh.log" | xargs)" = 1
check "github, gh not logged in: the key waits in TMPDIR" test -n "$(find "$T/tmp" -name deployer)"
rm -rf "${T:?}/tmp/"*

reset; touch "$T/auth-ok"; state env=1 registry_token=0 image=0 key=1
run DEVOPS_FORGE=github
check "github .env: IMAGE on ghcr.io, owner in lower case" has "IMAGE=ghcr.io/ops/demo in /opt/demo/.env"
check "github .env: REGISTRY_TOKEN is a read:packages PAT" has "read:packages"
check "github .env: no Forgejo wording" lacks forgejo

reset; state key=1 env=0
run DEVOPS_FORGE=github
check "github, no .env: template item names ghcr.io and the login" has "IMAGE=ghcr.io/ops/demo" "REGISTRY_USER=Ops"

# --- forgejo --------------------------------------------------------------
reset; touch "$T/auth-ok"; state "${ALL[@]}"
run
check "forgejo default, no token: WAIT 1" grep -qx 'WAIT 1' <<<"$OUT"
check "forgejo, no token: secrets and the REGISTRY variable of Ops/demo" \
  has "repository secrets of Ops/demo" "REGISTRY        = git.example.com"
check "forgejo: key comment demo-deploy@forgejo" grep -q 'demo-deploy@forgejo' "$T/ak.log"
check "forgejo: gh never called" test ! -e "$T/gh.log"
rm -rf "${T:?}/tmp/"*

reset; state "${ALL[@]}"
run FORGEJO_API_TOKEN=tok
A=https://git.example.com/api/v1/repos/Ops/demo/actions
check "forgejo + token: secrets through the API" \
  logged "$T/curl.log" "PUT $A/secrets/DEPLOY_SSH_KEY" "PUT $A/secrets/DEPLOY_HOST" "PUT $A/secrets/DEPLOY_HOST_KEY"
check "forgejo + token: variable REGISTRY = DEVOPS_REGISTRY" grep -q '"value": "git.example.com"' "$T/api-REGISTRY"
check "forgejo + token: no key left on disk" no_key_left
check "forgejo + token: asks for the REGISTRY_TOKEN secret only" has "WAIT 1" "scope write:package"

reset; state env=1 registry_token=0 image=0 key=1
run
check "forgejo .env: IMAGE on DEVOPS_REGISTRY, owner in lower case" has "IMAGE=git.example.com/ops/demo in /opt/demo/.env"
check "forgejo .env: REGISTRY_TOKEN is a read:package token" has "a Forgejo token of Ops with scope read:package"

# --- owner and repository from the git remote ------------------------------
# A transferred repository: ssh form with a port and an IP, owner an
# organization, repository name not the app name.
reset; state env=1 registry_token=1 image=0 registry_user=0 key=0
remote ssh://git@203.0.113.9:2222/acme/shop.git
NAME=shop_v4 run FORGEJO_API_TOKEN=tok
A=https://git.example.com/api/v1/repos/acme/shop/actions
check "remote: secrets go to the repository of the remote" \
  logged "$T/curl.log" "PUT $A/secrets/DEPLOY_SSH_KEY" "PUT $A/secrets/DEPLOY_HOST" "PUT $A/secrets/DEPLOY_HOST_KEY"
check "remote: says where the repository came from" has "repository acme/shop (from the git remote)"
check "remote: IMAGE owner from the remote, name from the app" has "IMAGE=git.example.com/acme/shop_v4 in /opt/shop_v4/.env"
check "remote, owner is not the login: variable REGISTRY_USER = login" grep -q '"value": "Ops"' "$T/api-REGISTRY_USER"
check "remote, owner is not the login: .env needs REGISTRY_USER" has "REGISTRY_USER=Ops in /opt/shop_v4/.env"

reset; state env=1 registry_token=1 image=1 registry_user=0 key=1
remote https://git.example.com/ops/demo.git
run FORGEJO_API_TOKEN=tok DEVOPS_REGISTRY_LOGIN=ops
no_registry_user() { ! has "REGISTRY_USER=" && test ! -e "$T/api-REGISTRY_USER"; }
check "owner is the login: no REGISTRY_USER asked, no variable set" no_registry_user

# An organization secret REGISTRY_TOKEN serves every repository of the
# organization: nothing to ask for.
reset; state "${ALL[@]}"
echo '[{"name":"REGISTRY_TOKEN"}]' > "$T/org-secrets"
remote https://git.example.com/acme/shop.git
run FORGEJO_API_TOKEN=tok
check "organization secret REGISTRY_TOKEN: DONE" grep -qx 'DONE demo@demo-host' <<<"$OUT"
check "organization secret REGISTRY_TOKEN: read from the organization" \
  logged "$T/curl.log" "GET https://git.example.com/api/v1/orgs/acme/actions/secrets"

reset; state "${ALL[@]}"
remote https://git.example.com/acme/shop.git
run FORGEJO_API_TOKEN=tok
check "no REGISTRY_TOKEN in the repository or the organization: asked for" has "WAIT 1" "scope write:package"

reset; state "${ALL[@]}"
remote https://git.example.com/acme/site.git
run FORGEJO_API_TOKEN=tok FORGEJO_REPO=other/thing
check "FORGEJO_REPO wins over the remote" logged "$T/curl.log" \
  "PUT https://git.example.com/api/v1/repos/other/thing/actions/secrets/DEPLOY_HOST"

reset; touch "$T/auth-ok"; state env=1 registry_token=1 image=0 registry_user=1 key=0
remote git@github.com:Acme/Site.git
run DEVOPS_FORGE=github
check "github remote: secrets set in Acme/Site" \
  test "$(grep -c -- '^secret set DEPLOY_[A-Z_]* --repo Acme/Site$' "$T/gh.log")" = 3
check "github remote: IMAGE ghcr.io/acme/<app>" has "IMAGE=ghcr.io/acme/demo in /opt/demo/.env"

# --- Forgejo token from DEVOPS_FORGEJO_TOKEN_CMD ----------------------------
reset; state "${ALL[@]}"
remote -
run DEVOPS_FORGEJO_TOKEN_CMD='printf cmdtok'
check "token command: secrets through the API" logged "$T/curl.log" \
  "PUT https://git.example.com/api/v1/repos/Ops/demo/actions/secrets/DEPLOY_SSH_KEY"
check "token command: the token goes in a header file" grep -qxF 'Authorization: token cmdtok' "$T/curl-headers.log"
check "token never in curl arguments" eval "! grep -q cmdtok $T/curl-args.log"
check "token never in the output" lacks cmdtok
check "header file deleted" no_key_left

reset; state "${ALL[@]}"
run DEVOPS_FORGEJO_TOKEN_CMD=false
check "failing token command: exit 1" test "$RC" = 1
check "failing token command: how to store the token" has "devops-forgejo" "write:repository" "write:organization"
check "failing token command: stops before the server" test ! -e "$T/ssh.log"

reset; state "${ALL[@]}"
run DEVOPS_FORGE=gitlab
check "unknown forge: exit 1" test "$RC" = 1
check "unknown forge: names DEVOPS_FORGE" has "DEVOPS_FORGE=gitlab: expected forgejo or github"

# --- name collision -------------------------------------------------------
# compose names volumes and networks <app>_<name>: volume x_data of demo and
# volume data of demo_x are both demo_x_data. The server reports a project
# whose name is <app>_* or a prefix of <app>_ (integration_test.sh runs the
# server side); the run stops before the key is installed.
reset; state collide=demo
NAME=demo_x run
check "collision: exit 1" test "$RC" = 1
check "collision: names both projects" has 'project demo_x collides with project demo on demo-host'
check "collision: no key installed" test ! -e "$T/ak.log"

echo
if [[ $FAILED -ne 0 ]]; then echo "$FAILED failed"; exit 1; fi
echo "all passed"
