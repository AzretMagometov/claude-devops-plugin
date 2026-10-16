# Forgejo Actions: CI/CD on the Forgejo host `DEVOPS_REGISTRY`

Template: `assets/.forgejo/workflows/ci.yml`, derived from a working
pipeline. Only the `test` job is stack-specific.

## Pipeline

| Job | When | What |
|-----|------|------|
| `test` | every push and pull request | project gates against real PostgreSQL and Redis service containers |
| `build` | push to `main` after green `test` | buildx build (linux/amd64) → trivy scan → push `<DEVOPS_REGISTRY>/<DEVOPS_REGISTRY_USER>/<app>:<sha>` |
| `deploy` | after `build`, or manual run | `ssh deployer@<host> "deploy <sha>"` |

The `deploy` job does not run compose. The deployer key on the server is bound
to a forced command (`/usr/local/bin/deploy-app <app>`): it pulls the tag, reads
the compose file from the image, runs `up --wait`, and rolls back to the last
good tag if the stack is not healthy.

Rollback to any earlier build: Actions → ci → Run workflow, `image_tag` = the
commit hash. Nothing is rebuilt.

## Runner quirks the template already handles

- `github.server_url` can be `http://localhost:3000` (the default ROOT_URL),
  unreachable from the job container. URLs are built from the repository
  variable `REGISTRY` (`https://${{ vars.REGISTRY }}/${{ github.repository }}`);
  `add-project.sh` with `FORGEJO_API_TOKEN` sets it to `DEVOPS_REGISTRY`.
  A job fails at once with a clear message when it is not set.
- The registry login is `github.repository_owner`. For a repository of an
  organization, put the login of the token owner into that step.
- `/bin/sh` in job containers is dash, which has no `pipefail`:
  `defaults.run.shell: bash`.
- Sources are fetched with plain `git fetch <sha>`, not `actions/checkout`.
- The runner home holds a foreign `~/.ssh/id_ed25519.pub`; ssh would offer it
  instead of the deploy key. The key goes to its own directory with
  `-F /dev/null -o IdentitiesOnly=yes`.
- The default buildx driver cannot export cache to a registry. The template
  creates a `docker-container` builder; the cache is an OCI image manifest,
  because the Forgejo registry stores images only.
- The image is scanned before it is pushed (`--load`, then trivy, then push).
- Step logs are not readable through the API (a web route with a CSRF token).

## Secrets and tokens

| Where | Name | Value |
|-------|------|-------|
| Forgejo repo variable | `REGISTRY` | Forgejo host, `DEVOPS_REGISTRY` |
| Forgejo repo secret | `REGISTRY_TOKEN` (or `<PREFIX>_REGISTRY_TOKEN`, as the project's `ci.yml` names it) | Forgejo token, scope `write:package` |
| Forgejo repo secret | `DEPLOY_HOST` | server IP |
| Forgejo repo secret | `DEPLOY_SSH_KEY` | private half of the deployer key |
| Forgejo repo secret | `DEPLOY_HOST_KEY` | `<IP> ssh-ed25519 AAAA...` |
| server `/opt/<app>/.env` | `REGISTRY_TOKEN` | Forgejo token, scope `read:package` (pull only) |

Two registry tokens, not one: the server token cannot push, so a stolen
server `.env` cannot replace an image. Forgejo creates scoped tokens only in
the web UI (Settings → Applications) or with a password; the user creates them.

`DEPLOY_HOST_KEY` comes over the already trusted admin session, not from
`ssh-keyscan` (that would trust whatever the network answers):

```bash
ssh <admin>@<host> cat /etc/ssh/ssh_host_ed25519_key.pub | awk -v h=<IP> '{print h, $1, $2}'
```

## Repository and secrets through the API

API token: `.forgejo-api-token` in the project root (git-ignored) or
`FORGEJO_API_TOKEN`; scope `write:repository`. Checked against Forgejo
13.0.2 (`https://<DEVOPS_REGISTRY>/api/swagger`).

```bash
. ~/.config/devops/env   # DEVOPS_REGISTRY, DEVOPS_REGISTRY_USER
API=https://$DEVOPS_REGISTRY/api/v1
AUTH="Authorization: token $(cat .forgejo-api-token)"

# Create the repository if it does not exist
curl -fsS -H "$AUTH" "$API/repos/$DEVOPS_REGISTRY_USER/<app>" >/dev/null \
  || curl -fsS -X POST -H "$AUTH" -H 'Content-Type: application/json' \
       -d '{"name":"<app>","private":true}' "$API/user/repos"

# Create or update a secret; the value comes on stdin, not in argv
put_secret() {
  python3 -c 'import json,sys; print(json.dumps({"data": sys.stdin.read()}))' \
    | curl -fsS -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
        --data @- "$API/repos/$DEVOPS_REGISTRY_USER/<app>/actions/secrets/$1"
}
printf '%s' '<IP>' | put_secret DEPLOY_HOST   # <<< would append a newline
put_secret DEPLOY_SSH_KEY < "$KEY_DIR/deployer"

# Names only; values are never readable back
curl -fsS -H "$AUTH" "$API/repos/$DEVOPS_REGISTRY_USER/<app>/actions/secrets"
```

Repository variables (non-secret): `POST`/`PUT
$API/repos/$DEVOPS_REGISTRY_USER/<app>/actions/variables/<NAME>` with `{"value": "..."}`.
Names starting with `GITHUB_` or `GITEA_` are reserved.
