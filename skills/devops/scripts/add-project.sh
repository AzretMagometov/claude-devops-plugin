#!/usr/bin/env bash
# Prepares a server made by web-init for one project, from the Mac:
#   /opt/<app> root:root 755, /opt/<app>/state deployer 755,
#   .env ownership root:deployer 640 (the file itself comes from the user; IMAGE
#   and REGISTRY_TOKEN in it are checked),
#   a deploy key bound to `deploy-app <app>` in /home/deployer/.ssh/authorized_keys,
#   the repository secrets DEPLOY_SSH_KEY, DEPLOY_HOST, DEPLOY_HOST_KEY.
#
#   bash add-project.sh <host> <app>
#
# DEVOPS_FORGE (~/.config/devops/env) picks where the repository lives:
#   forgejo (default)  FORGEJO_API_TOKEN (scope write:repository) uploads the
#                      secrets and the repository variable REGISTRY (=
#                      $DEVOPS_REGISTRY, read by the CI template) through the
#                      API; FORGEJO_REPO defaults to $DEVOPS_REGISTRY_USER/<app>,
#                      FORGEJO_URL to https://$DEVOPS_REGISTRY.
#   github             `gh secret set` uploads the secrets when gh is logged in;
#                      GITHUB_REPO defaults to $DEVOPS_REGISTRY_USER/<app>, the
#                      image to ghcr.io/<owner>/<app> in lower case.
# Without the token or gh the private key stays in a temporary directory for a
# manual paste, and the script says how to delete it.
#
# Idempotent: the key line is found by its comment <app>-deploy@<forge>, and an
# existing key is kept. To replace it, delete that line and run again.
# What only the user can provide is printed in one block under "Waiting for you:".
set -euo pipefail

f=$0; while [ -L "$f" ]; do t=$(readlink "$f"); case $t in /*) f=$t ;; *) f=$(dirname "$f")/$t ;; esac; done
DEVOPS_DIR=$(cd "$(dirname "$f")/.." && pwd)
# shellcheck source=SCRIPTDIR/../lib/config.sh
. "$DEVOPS_DIR/lib/config.sh"
die() { echo "Error: $*" >&2; exit 1; }
case $DEVOPS_FORGE in
  forgejo) devops_require DEVOPS_ADMIN DEVOPS_REGISTRY DEVOPS_REGISTRY_USER || exit 1 ;;
  github) devops_require DEVOPS_ADMIN DEVOPS_REGISTRY_USER || exit 1 ;;
  *) die "DEVOPS_FORGE=${DEVOPS_FORGE}: expected forgejo or github" ;;
esac
ADMIN=$DEVOPS_ADMIN
[[ $# -eq 2 ]] || die "usage: $(basename "$0") <host> <app>"
HOST=$1 APP=$2
[[ $APP =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "project name \"${APP}\" does not match ^[a-z0-9][a-z0-9_-]{0,40}$"
IMAGE=$(devops_image "$APP")
if [[ $DEVOPS_FORGE == github ]]; then
  REPO=${GITHUB_REPO:-$DEVOPS_REGISTRY_USER/$APP}
  PULL_TOKEN="a GitHub personal access token (classic) with scope read:packages"
  ENV_HINT="IMAGE=${IMAGE}, REGISTRY_USER is your GitHub login, REGISTRY_TOKEN is ${PULL_TOKEN}"
else
  FORGEJO_URL=${FORGEJO_URL:-https://$DEVOPS_REGISTRY}
  REPO=${FORGEJO_REPO:-$DEVOPS_REGISTRY_USER/$APP}
  PULL_TOKEN="a Forgejo token with scope read:package"
  ENV_HINT="REGISTRY_TOKEN is a read:package token"
fi
COMMENT=$APP-deploy@$DEVOPS_FORGE
SSH=(ssh -o ConnectTimeout=15 "$ADMIN@$HOST")
WAIT=()

# --- server: directories, .env, current key ------------------------------
STATE=$("${SSH[@]}" "sudo APP=$APP COMMENT=$COMMENT bash -s" <<'REMOTE'
set -euo pipefail
[ -x /usr/local/bin/deploy-app ] && id deployer >/dev/null 2>&1 || { echo "web=0"; exit 0; }
echo "web=1"
install -d -m 755 -o root -g root "/opt/$APP"
install -d -m 755 -o deployer -g deployer "/opt/$APP/state"
ENV=/opt/$APP/.env
if [ -f "$ENV" ]; then
  chown root:deployer "$ENV"
  chmod 640 "$ENV"
  echo "env=1"
  grep -qE '^REGISTRY_TOKEN=.+' "$ENV" && echo "registry_token=1" || echo "registry_token=0"
  grep -qE '^IMAGE=.+' "$ENV" && echo "image=1" || echo "image=0"
else
  echo "env=0"
fi
grep -q " $COMMENT\$" /home/deployer/.ssh/authorized_keys 2>/dev/null && echo "key=1" || echo "key=0"
awk '{print "host_key=" $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub
REMOTE
)
fact() { sed -n "s/^$1=//p" <<<"$STATE"; }
[[ $(fact web) == 1 ]] || die "no deploy-app or deployer on $HOST: run web-init $HOST first"
echo "✓ /opt/${APP} root 755, /opt/${APP}/state deployer 755"

if [[ $(fact env) == 1 ]]; then
  echo "✓ /opt/${APP}/.env root:deployer 640"
  [[ $(fact registry_token) == 1 ]] \
    || WAIT+=("REGISTRY_TOKEN in /opt/${APP}/.env: ${PULL_TOKEN}")
  [[ $(fact image) == 1 ]] \
    || WAIT+=("IMAGE=${IMAGE} in /opt/${APP}/.env: deploy-app cannot roll out without it")
else
  WAIT+=("/opt/${APP}/.env from the template assets/.env.example (${ENV_HINT}):
   ssh ${ADMIN}@${HOST} 'sudo install -m 640 -o root -g deployer /dev/stdin /opt/${APP}/.env' < .env")
fi

# --- deploy key -----------------------------------------------------------
# put_secret NAME < value: one repository secret on the forge.
if [[ $DEVOPS_FORGE == github ]]; then
  command -v gh > /dev/null && gh auth status > /dev/null 2>&1 && UPLOAD=1 || UPLOAD=0
  put_secret() { gh secret set "$1" --repo "$REPO" > /dev/null; }
else
  [[ -n ${FORGEJO_API_TOKEN:-} ]] && UPLOAD=1 || UPLOAD=0
  API=$FORGEJO_URL/api/v1/repos/$REPO/actions
  # forgejo_api METHOD PATH FIELD < value: JSON {FIELD: value} to the API.
  forgejo_api() {
    python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.stdin.read()}))' "$3" \
      | curl -fsS -X "$1" -H "Authorization: token $FORGEJO_API_TOKEN" \
          -H 'Content-Type: application/json' --data @- "$API/$2" > /dev/null
  }
  put_secret() { forgejo_api PUT "secrets/$1" data; }
fi

if [[ $(fact key) == 1 ]]; then
  echo "✓ key ${COMMENT} already in authorized_keys, kept (to replace it, delete the line and run again)"
else
  # An explicit template: BSD mktemp -d alone may ignore TMPDIR.
  KEY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/add-project.XXXXXX")
  KEY=$KEY_DIR/deployer
  ssh-keygen -q -t ed25519 -N '' -C "$COMMENT" -f "$KEY"
  IP=$(ssh -G "$HOST" | awk '$1 == "hostname" {print $2}')
  if [[ $UPLOAD == 1 ]]; then
    # The private half goes to the forge first: if the upload fails, the server
    # never gets a key nobody holds, and the next run starts clean.
    put_secret DEPLOY_SSH_KEY < "$KEY" || { rm -rf "$KEY_DIR"; die "${DEVOPS_FORGE} rejected DEPLOY_SSH_KEY for ${REPO}"; }
    printf '%s' "$IP" | put_secret DEPLOY_HOST
    printf '%s' "$IP $(fact host_key)" | put_secret DEPLOY_HOST_KEY
    rm -P "$KEY" 2>/dev/null || shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
    echo "✓ secrets DEPLOY_SSH_KEY, DEPLOY_HOST, DEPLOY_HOST_KEY in ${REPO}; private key deleted"
  elif [[ $DEVOPS_FORGE == github ]]; then
    WAIT+=("repository secrets of ${REPO}: run these after gh auth login, or run this script again once gh is logged in:
   gh secret set DEPLOY_SSH_KEY --repo ${REPO} < ${KEY} && rm -P ${KEY}
   gh secret set DEPLOY_HOST --repo ${REPO} --body '${IP}'
   gh secret set DEPLOY_HOST_KEY --repo ${REPO} --body '${IP} $(fact host_key)'")
  else
    WAIT+=("repository secrets of ${REPO} (Settings → Actions → Secrets) and the variable REGISTRY (Settings → Actions → Variables), or run again with FORGEJO_API_TOKEN:
   DEPLOY_SSH_KEY  = contents of ${KEY} (pbcopy < ${KEY}), then: rm -P ${KEY}
   DEPLOY_HOST     = ${IP}
   DEPLOY_HOST_KEY = ${IP} $(fact host_key)
   REGISTRY        = ${DEVOPS_REGISTRY} (variable, not secret)")
  fi
  LINE="restrict,command=\"/usr/local/bin/deploy-app ${APP}\" $(cut -d' ' -f1,2 "$KEY.pub") ${COMMENT}"
  rm -f "$KEY.pub"
  [[ -f $KEY ]] || rmdir "$KEY_DIR"
  # Rewritten as a whole and installed root:root 644: deployer cannot change it.
  "${SSH[@]}" "sudo COMMENT=$COMMENT LINE=$(printf %q "$LINE") bash -s" <<'REMOTE'
set -euo pipefail
AK=/home/deployer/.ssh/authorized_keys
TMP=$(mktemp)
{ grep -v " $COMMENT\$" "$AK" 2>/dev/null || true; printf '%s\n' "$LINE"; } > "$TMP"
install -m 644 -o root -g root "$TMP" "$AK"
rm -f "$TMP"
REMOTE
  echo "✓ authorized_keys: ${COMMENT} → deploy-app ${APP}"
fi

if [[ $DEVOPS_FORGE == forgejo && $UPLOAD == 1 ]]; then
  # The CI template builds the image and source URLs from this variable:
  # github.server_url can be an address the job container cannot reach.
  # POST creates it, PUT updates an existing one.
  printf '%s' "$DEVOPS_REGISTRY" | forgejo_api POST variables/REGISTRY value 2>/dev/null \
    || printf '%s' "$DEVOPS_REGISTRY" | forgejo_api PUT variables/REGISTRY value \
    || die "Forgejo rejected the variable REGISTRY for ${REPO}"
  echo "✓ variable REGISTRY=${DEVOPS_REGISTRY} in ${REPO}"
  curl -fsS -H "Authorization: token $FORGEJO_API_TOKEN" "$API/secrets" | grep -qE '"name":"[A-Z0-9_]*REGISTRY_TOKEN"' \
    || WAIT+=("secret REGISTRY_TOKEN (or <PREFIX>_REGISTRY_TOKEN, as in the project ci.yml) in ${REPO}: a Forgejo token with scope write:package (CI pushes the image)")
fi

if [[ ${#WAIT[@]} -eq 0 ]]; then
  echo "DONE ${APP}@${HOST}"
  exit 0
fi
echo
echo "Waiting for you:"
for i in "${!WAIT[@]}"; do printf '%d. %s\n' $((i + 1)) "${WAIT[$i]}"; done
echo "WAIT ${#WAIT[@]}"
