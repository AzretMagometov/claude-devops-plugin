# shellcheck shell=bash
# Personal settings of the devops scripts, sourced by bin/* and scripts/*.
# The file $DEVOPS_CONFIG (default ~/.config/devops/env) holds KEY=value lines
# and is sourced; a key already set in the environment wins over the file.
# Keys and defaults: env.example next to this directory.
# devops_require KEY... prints an error naming the key and the file and
# returns 1 when a key is empty.
# devops_image APP prints the image for IMAGE= in /opt/APP/.env from
# DEVOPS_FORGE and the registry keys, or <registry>/<owner>/APP without them.

DEVOPS_CONFIG=${DEVOPS_CONFIG:-$HOME/.config/devops/env}
_devops_keep=""
for _k in DEVOPS_ADMIN DEVOPS_PUBKEY_FILE DEVOPS_IGNOREIP DEVOPS_TZ DEVOPS_ACME_EMAIL DEVOPS_REGISTRY DEVOPS_REGISTRY_USER DEVOPS_FORGE; do
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

devops_require() {
  local k
  for k in "$@"; do
    [ -n "${!k:-}" ] || { echo "Error: $k is not set: add it to $DEVOPS_CONFIG or set it in the environment" >&2; return 1; }
  done
}

devops_image() {
  if [ "$DEVOPS_FORGE" = github ] && [ -n "${DEVOPS_REGISTRY_USER:-}" ]; then
    # GHCR takes lower-case image names only.
    echo "ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"$DEVOPS_REGISTRY_USER")/$1"
  elif [ "$DEVOPS_FORGE" != github ] && [ -n "${DEVOPS_REGISTRY:-}" ] && [ -n "${DEVOPS_REGISTRY_USER:-}" ]; then
    echo "$DEVOPS_REGISTRY/$DEVOPS_REGISTRY_USER/$1"
  else
    echo "<registry>/<owner>/$1"
  fi
}
