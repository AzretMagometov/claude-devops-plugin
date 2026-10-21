# Forgejo Actions: CI/CD on the Forgejo host `DEVOPS_REGISTRY`

Template: `assets/.forgejo/workflows/ci.yml`, derived from a working
pipeline. Only the `test` job is stack-specific.

## Pipeline

| Job | When | What |
|-----|------|------|
| `test` | every push and pull request | project gates against real PostgreSQL and Redis service containers |
| `build` | push to `main` after green `test` | buildx build (linux/amd64) → trivy scan → push `<DEVOPS_REGISTRY>/<owner>/<app>:<sha>` (lower case) |
| `deploy` | after `build`, or manual run | `ssh deployer@<host> "deploy <sha>"` |

The `deploy` job does not run compose. The deployer key on the server is bound
to a forced command (`/usr/local/bin/deploy-app <app>`): it pulls the tag, reads
the compose file from the image, runs `up --wait`, and rolls back to the last
good tag if the stack is not healthy.

Rollback to any earlier build: Actions → ci → Run workflow, `image_tag` = the
commit hash. Nothing is rebuilt.

## Runner prerequisites

The `test` and `build` jobs download nothing on a normal run: the image with
uv is on the runner host, the packages are in a uv cache on the runner host,
the sources come from Forgejo, and trivy reads its DB from a cache volume
that a daily timer fills. `build` reaches the network only for the sources
and the registry push; a Dockerfile with digest pins (`SKILL.md`, step 2)
needs no registry lookups for its base images. A slow route to pypi.org then
costs time only on a cache miss. Do these steps once on the runner host.

1. Build the job image from `assets/ci-image/Dockerfile`. It is
   `python:3.12-slim-bookworm`, the base of the application image, plus uv.
   Copy the directory to the runner host; do not copy it into the project.

   ```bash
   docker build -t local/ci-python:3.12-uv0.10.4 --build-arg UV_VERSION=0.10.4 <dir>
   ```

   The tag, `UV_VERSION` and the `image:` line of the project `ci.yml` change
   together. The runner uses the local image only with
   `container.force_pull: false` (the default). If the image is not on the
   host, the runner tries to pull `local/ci-python` from Docker Hub and the
   job fails with `pull access denied`.

2. Create the cache directory:

   ```bash
   install -d /opt/forgejo-runner/cache/uv
   ```

3. Allow the cache volume in the runner `config.yml` and restart the runner:

   ```yaml
   container:
     force_pull: false
     valid_volumes:
       - /opt/forgejo-runner/cache/uv
   ```

   forgejo-runner v13 (`act/container/docker/run.go`, `sanitizeConfig`)
   matches each bind source and each named volume of the job and service
   containers against the `valid_volumes` globs. A volume that matches no
   entry is dropped, the runner log gets `[<path>] is not a valid volume,
   will be ignored`, and the job runs on. An empty list drops every job
   volume. So a missing entry does not fail the job: every run downloads all
   dependencies again. Look for that line in the runner log when the `test`
   job is slow.

4. Bound the disk of the runner host with a weekly timer. `docker image
   prune -f` removes dangling images only: the `build` job removes the app
   image after the push, and base, tool and service images stay, so no run
   pulls them again. Do not add `-a --filter until=...`: `until` is the
   creation time of the image, not the time of its last use, so it removes
   trivy and the service images every week. The buildx prune keeps the cache
   of the `ci` builder under 3 GB. buildx keeps builders per user, so the
   service runs as the user of the runner service (`User=` of its unit).

   ```ini
   # /etc/systemd/system/ci-disk-prune.service
   [Unit]
   Description=Remove dangling Docker images and bound the build cache
   Requires=docker.service
   After=docker.service

   [Service]
   Type=oneshot
   User=<runner user>
   ExecStart=/usr/bin/docker image prune -f
   ExecStart=/usr/bin/docker buildx prune --builder ci -f --max-used-space 3gb

   # /etc/systemd/system/ci-disk-prune.timer
   [Unit]
   Description=Weekly CI disk prune

   [Timer]
   OnCalendar=weekly
   Persistent=true
   RandomizedDelaySec=1h

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   systemctl daemon-reload && systemctl enable --now ci-disk-prune.timer
   ```

   Replace an earlier unit (`docker-image-prune.*` or a script in
   `/usr/local/bin/ci-disk-prune` with `image prune -af`) with this one.
   Builders of earlier template versions, one per repository, are not used
   any more: `docker buildx ls`, then `docker buildx rm <name>`.

5. Refresh the trivy DB with a daily timer. The `build` job scans with
   `--skip-db-update` and fails at once when the volume `trivy-cache` has no
   DB.

   ```ini
   # /etc/systemd/system/trivy-db-update.service
   [Unit]
   Description=Download the trivy vulnerability DB into the volume trivy-cache
   Requires=docker.service
   After=docker.service network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   User=<runner user>
   ExecStart=/usr/bin/docker run --rm -v trivy-cache:/root/.cache/trivy aquasec/trivy:0.74.0 image --download-db-only --skip-version-check --disable-telemetry --no-progress

   # /etc/systemd/system/trivy-db-update.timer
   [Unit]
   Description=Daily trivy DB update

   [Timer]
   OnCalendar=daily
   Persistent=true
   RandomizedDelaySec=1h

   [Install]
   WantedBy=timers.target
   ```

   ```bash
   systemctl daemon-reload && systemctl enable --now trivy-db-update.timer
   systemctl start trivy-db-update.service   # once by hand: the first DB
   ```

   The trivy tag in the unit and in `ci.yml` change together.

6. A stale login to another registry in `~/.docker/config.json` of the
   runner user (ghcr.io, say) breaks a build with 403 on an unpinned image:
   `docker logout <registry>`. Digest pins avoid the request entirely.

7. In Forgejo: every push adds a `:<sha>` version to the registry. Per owner
   (user or organization): Settings → Packages → Cleanup rules → add a rule:
   type `container`, keep the 5 most recent versions, remove pattern `.*`.
   Rollback (`image_tag`) reaches only the versions the rule keeps.

The uv cache grows with each new package version; `uv cache prune` in the CI
image with the cache mounted removes the entries no longer used.

## Runner quirks the template already handles

- `github.server_url` can be `http://localhost:3000` (the default ROOT_URL),
  unreachable from the job container. URLs are built from the repository
  variable `REGISTRY` (`https://${{ vars.REGISTRY }}/${{ github.repository }}`);
  `add-project.sh` with the API token sets it to `DEVOPS_REGISTRY`.
  A job fails at once with a clear message when it is not set.
- The registry login is the repository variable `REGISTRY_USER`, else
  `github.repository_owner`. An organization cannot log in: for its
  repositories `add-project.sh` sets `REGISTRY_USER` to `DEVOPS_REGISTRY_LOGIN`.
- `/bin/sh` in job containers is dash, which has no `pipefail`:
  `defaults.run.shell: bash`.
- The job image of `test` has neither git nor node, so no `actions/checkout`:
  the step downloads `/api/v1/repos/{owner}/{repo}/archive/<sha>.tar.gz` with
  the automatic token in `Authorization: token` and extracts it with Python
  (`tarfile`, filter `data`). On this route Forgejo 15 resolves the automatic
  token to the running task and gives it read access to the task's own
  repository (`services/auth/method/oauth2.go`,
  `routers/api/v1/permissions/repo_access.go`). The archive has one top
  directory, `<repo>/`, which the step strips. The `build` job runs on the
  runner host, which has git, and fetches the commit with `git fetch <sha>`.
- The runner home holds a foreign `~/.ssh/id_ed25519.pub`; ssh would offer it
  instead of the deploy key. The key goes to its own directory with
  `-F /dev/null -o IdentitiesOnly=yes`.
- All repositories build with one `docker-container` builder, `ci`. Its
  local cache survives between runs on the runner host; there is no registry
  cache. The builder is created with
  `--buildkitd-flags '--oci-worker-gc-keepstorage 1000,10000,3000'`
  (reserved, min free, max used, MB): buildkit GC keeps the cache under
  ~3 GB. The flag applies at creation only: to change it, `docker buildx rm
  ci` and let the next run create the builder again.
- The loaded `<image>:<sha>` is removed after the push, also on a failed run.
- The image is scanned before it is pushed (`--load`, then trivy, then push).
- trivy scans offline: `--skip-db-update --skip-java-db-update
  --skip-check-update --skip-version-check --disable-telemetry
  --offline-scan`. The DB comes from the volume `trivy-cache`, which the
  timer `trivy-db-update` fills (prerequisite 5). With an empty volume trivy
  says only "--skip-db-update cannot be specified on the first run", so a
  step before the scans checks the volume and names the timer.
- Step logs are not readable through the API (a web route with a CSRF token).
  They lie on the Forgejo host as
  `<forgejo data>/actions_log/<owner>/<repo>/<xx>/<task id>.log.zst`
  (`<forgejo data>` is `/var/lib/forgejo/data` for a package install); the
  task id of each job is `id` in `GET /repos/{owner}/{repo}/actions/tasks`:

  ```bash
  ssh <DEVOPS_ADMIN>@<DEVOPS_REGISTRY> \
    'sudo find /var/lib/forgejo/data/actions_log/<owner>/<repo> -name "<task id>.log.zst" -exec cat {} +' \
    | zstd -dc
  ```

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

API token: `FORGEJO_API_TOKEN`, else the output of `DEVOPS_FORGEJO_TOKEN_CMD`
(a keychain lookup, never a plain-text file); scopes `write:repository` and
`write:organization` (secrets of an organization repository; the login must
be an owner of the organization). Owner and repository come from the git
remote (`config-schema.md`). Checked against Forgejo 13.0.2
(`https://<DEVOPS_REGISTRY>/api/swagger`).

```bash
. ${CLAUDE_SKILL_DIR}/lib/config.sh && devops_repo .   # DEVOPS_REGISTRY, DEVOPS_REPO_OWNER, DEVOPS_REPO_NAME
API=https://$DEVOPS_REGISTRY/api/v1
R=$DEVOPS_REPO_OWNER/${DEVOPS_REPO_NAME:-<app>}
# The header goes in a file only you can read: curl arguments show in ps.
AUTH=$(umask 077 && mktemp) && printf 'Authorization: token %s\n' "$(devops_forgejo_token)" > "$AUTH"

# Create the repository if it does not exist
curl -fsS -H @"$AUTH" "$API/repos/$R" >/dev/null \
  || curl -fsS -X POST -H @"$AUTH" -H 'Content-Type: application/json' \
       -d '{"name":"<app>","private":true}' "$API/user/repos"

# Create or update a secret; the value comes on stdin, not in argv
put_secret() {
  python3 -c 'import json,sys; print(json.dumps({"data": sys.stdin.read()}))' \
    | curl -fsS -X PUT -H @"$AUTH" -H 'Content-Type: application/json' \
        --data @- "$API/repos/$R/actions/secrets/$1"
}
printf '%s' '<IP>' | put_secret DEPLOY_HOST   # <<< would append a newline
put_secret DEPLOY_SSH_KEY < "$KEY_DIR/deployer"

# Names only; values are never readable back
curl -fsS -H @"$AUTH" "$API/repos/$R/actions/secrets"
rm -f "$AUTH"
```

## Reading the forge state

`scripts/forge-check.sh` reads these endpoints with GET only (checked
against Forgejo 15.0.10, `https://<DEVOPS_REGISTRY>/swagger.v1.json`):

| Fact | Endpoint | Note |
|------|----------|------|
| token | `/user` | 401/403: token rejected |
| repository | `/repos/{owner}/{repo}` | 200 or 404 |
| owner type | `/orgs/{owner}` | 200 organization, 404 user (`/users/{name}` answers 200 for both) |
| secret names | `/repos/{o}/{r}/actions/secrets`, `/orgs/{org}/actions/secrets` | users have no list endpoint for their own secrets |
| variable names | `/repos/{o}/{r}/actions/variables`, `/orgs/{org}/actions/variables`, `/user/actions/variables` | the user endpoint shows only the token user |
| runners | `/admin/actions/runners` (instance runners; `read:admin` as a site administrator), `/orgs/{org}/actions/runners` or `/user/actions/runners`, `/repos/{o}/{r}/actions/runners` | each endpoint lists only runners of its own scope |
| stuck pipeline | `/repos/{o}/{r}/actions/runs?status=waiting` | `total_count` |
| image | `/packages/{owner}?type=container&q=<app>` | `q` matches a substring: compare `name` exactly |

Owner-level secrets and variables apply to every repository of the owner; a
repository entry with the same name wins. Runner `status`: `idle` (online, no
job for 10 s) and `active` (running a job) are online, `offline` means no
contact for over a minute (`models/actions/runner.go`).

Repository variables (non-secret): `POST`/`PUT
$API/repos/$R/actions/variables/<NAME>` with `{"value": "..."}`.
Names starting with `GITHUB_` or `GITEA_` are reserved.
