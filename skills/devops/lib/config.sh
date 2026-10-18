# shellcheck shell=bash
# Personal settings of the devops scripts, sourced by bin/* and scripts/*.
# The file $DEVOPS_CONFIG (default ~/.config/devops/env) holds KEY=value lines
# and is sourced; a key already set in the environment wins over the file.
# Keys and defaults: env.example next to this directory.
# devops_require KEY... prints an error naming the key and the file and
# returns 1 when a key is empty.
# devops_remote_parse URL prints "host owner repo" of a git remote: https or
# http, ssh://[user@]host[:port]/owner/repo and scp-like [user@]host:owner/repo,
# with or without .git and a trailing slash; owner and repo are the last two
# path segments. Returns 1 for anything else (a local path, one segment).
# devops_repo [DIR] sets DEVOPS_REPO_HOST, DEVOPS_REPO_OWNER, DEVOPS_REPO_NAME
# and DEVOPS_REPO_SOURCE for the project in DIR (default .). Repositories move
# between owners, so the owner comes from `git remote get-url origin` first,
# then from "repo" in DIR/.devops-config, then DEVOPS_REGISTRY_USER (name
# empty: the caller uses the app name). Returns 1 when no owner is known.
# Host rule: github.com stays github.com; any other remote host (domain, IP,
# ~/.ssh/config alias, any port) is the one configured Forgejo, so the host is
# DEVOPS_REGISTRY when it is set and the remote host otherwise.
# The app name stays separate: the repository may be named differently.
# devops_image APP prints the image for IMAGE= in /opt/APP/.env: the owner is
# DEVOPS_REPO_OWNER (after devops_repo), else DEVOPS_REGISTRY_USER, in lower
# case as registries require; <registry>/<owner>/APP without them.
# DEVOPS_REGISTRY_LOGIN (default DEVOPS_REGISTRY_USER) is the registry login:
# a real user, since an organization owns images but cannot log in.
# devops_forgejo_token prints FORGEJO_API_TOKEN, else the stdout of
# DEVOPS_FORGEJO_TOKEN_CMD (a keychain lookup, so no token sits in the env
# file). A failing or silent command prints how to store the token and
# returns 1; with neither set it returns 1 silently.

DEVOPS_CONFIG=${DEVOPS_CONFIG:-$HOME/.config/devops/env}
_devops_keep=""
for _k in DEVOPS_ADMIN DEVOPS_PUBKEY_FILE DEVOPS_IGNOREIP DEVOPS_TZ DEVOPS_ACME_EMAIL DEVOPS_REGISTRY DEVOPS_REGISTRY_USER \
  DEVOPS_REGISTRY_LOGIN DEVOPS_FORGE DEVOPS_FORGEJO_TOKEN_CMD; do
  [ -z "${!_k+x}" ] || _devops_keep="$_devops_keep $_k=$(printf %q "${!_k}")"
done
# shellcheck source=/dev/null
[ ! -f "$DEVOPS_CONFIG" ] || . "$DEVOPS_CONFIG"
eval "$_devops_keep"
unset _k _devops_keep
DEVOPS_PUBKEY_FILE=${DEVOPS_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}
DEVOPS_IGNOREIP=${DEVOPS_IGNOREIP:-}
DEVOPS_TZ=${DEVOPS_TZ:-}
DEVOPS_FORGE=${DEVOPS_FORGE:-forgejo}
DEVOPS_REGISTRY_LOGIN=${DEVOPS_REGISTRY_LOGIN:-${DEVOPS_REGISTRY_USER:-}}

devops_require() {
  local k
  for k in "$@"; do
    [ -n "${!k:-}" ] || { echo "Error: $k is not set: add it to $DEVOPS_CONFIG or set it in the environment" >&2; return 1; }
  done
}

devops_remote_parse() {
  local u=${1%/}
  u=${u%.git}
  if [[ $u =~ ^[a-z][a-z0-9+.-]*://([^@/]*@)?([^/:]+)(:[0-9]*)?/(.*/)?([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[2]} ${BASH_REMATCH[5]} ${BASH_REMATCH[6]}"
  elif [[ $u != *://* && $u =~ ^([^@/:]*@)?([^/:]+):(.*/)?([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[2]} ${BASH_REMATCH[4]} ${BASH_REMATCH[5]}"
  else
    return 1
  fi
}

devops_repo() {
  local dir=${1:-.} url parsed=""
  DEVOPS_REPO_SOURCE=remote
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) && parsed=$(devops_remote_parse "$url") || parsed=""
  if [ -z "$parsed" ] && [ -f "$dir/.devops-config" ]; then
    DEVOPS_REPO_SOURCE=.devops-config
    url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repo") or "")' "$dir/.devops-config" 2>/dev/null) \
      && parsed=$(devops_remote_parse "$url") || parsed=""
  fi
  if [ -n "$parsed" ]; then
    read -r DEVOPS_REPO_HOST DEVOPS_REPO_OWNER DEVOPS_REPO_NAME <<<"$parsed"
    [ "$DEVOPS_REPO_HOST" = github.com ] || DEVOPS_REPO_HOST=${DEVOPS_REGISTRY:-$DEVOPS_REPO_HOST}
    return 0
  fi
  # shellcheck disable=SC2034  # read by the callers
  DEVOPS_REPO_SOURCE=DEVOPS_REGISTRY_USER DEVOPS_REPO_OWNER=${DEVOPS_REGISTRY_USER:-} DEVOPS_REPO_NAME=""
  if [ "$DEVOPS_FORGE" = github ]; then DEVOPS_REPO_HOST=github.com; else DEVOPS_REPO_HOST=${DEVOPS_REGISTRY:-}; fi
  [ -n "$DEVOPS_REPO_OWNER" ]
}

devops_image() {
  local owner
  owner=$(tr '[:upper:]' '[:lower:]' <<<"${DEVOPS_REPO_OWNER:-${DEVOPS_REGISTRY_USER:-}}")
  if [ "$DEVOPS_FORGE" = github ] && [ -n "$owner" ]; then
    echo "ghcr.io/$owner/$1"
  elif [ "$DEVOPS_FORGE" != github ] && [ -n "${DEVOPS_REGISTRY:-}" ] && [ -n "$owner" ]; then
    echo "$DEVOPS_REGISTRY/$owner/$1"
  else
    echo "<registry>/<owner>/$1"
  fi
}

devops_forgejo_token() {
  local tok
  if [ -n "${FORGEJO_API_TOKEN:-}" ]; then printf '%s\n' "$FORGEJO_API_TOKEN"; return 0; fi
  [ -n "${DEVOPS_FORGEJO_TOKEN_CMD:-}" ] || return 1
  # The command's stderr is dropped: a keychain miss is explained below.
  tok=$(eval "$DEVOPS_FORGEJO_TOKEN_CMD" 2>/dev/null) || tok=""
  if [ -n "$tok" ]; then printf '%s\n' "$tok"; return 0; fi
  local store="security add-generic-password -s devops-forgejo -a ${DEVOPS_REGISTRY_LOGIN:-<login>} -w"
  [ "$(uname)" = Darwin ] || store="secret-tool store --label=devops-forgejo service devops-forgejo account ${DEVOPS_REGISTRY_LOGIN:-<login>}"
  echo "Error: DEVOPS_FORGEJO_TOKEN_CMD printed no token; store a Forgejo token (scopes write:repository and write:organization, as an owner of the organization) with: $store" >&2
  return 1
}
