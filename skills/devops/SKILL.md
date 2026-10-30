---
name: devops
description: >
  Deploy a project to a VPS: Docker Compose behind the server Traefik, images
  and CI/CD on Forgejo Actions of a self-hosted Forgejo or on GitHub Actions
  with GHCR. Use when there is a server and a project to put on it, when
  setting up or fixing the CI/CD pipeline of a project, when checking which server layers are installed, or when
  migrations reach production. Triggers: "deploy the project", "here is a
  server, here is a project", "set up deploy", "check the server",
  "migrations in production", "ci/cd", "forgejo actions", "github actions", "traefik",
  "задеплой проект", "вот сервер, вот проект", "настроить деплой",
  "проверь сервер", "миграции в проде". Not for hardening a bare server without a
  project (that is `vps-init`) and not for a VPN server (that is `vpn-deploy`).
---

# DevOps: project on a VPS

Scenario: "here is a server, here is a project". The server is built in layers, the
project is prepared on top, and the first deploy is the first CI run.

| Layer | Made by | Contents |
|-------|---------|----------|
| `vps` | `vps-init <IP> <name>` | user `DEVOPS_ADMIN` with key and sudo, root closed, ufw 22, fail2ban, auto-updates with a reboot at 04:00 (none on a VPN node) |
| `web` | `web-init <IP or alias>` | Docker with container logs in journald, `/opt/traefik` (Traefik + socket-proxy), network `proxy`, ufw 80/443, `deployer`, `/usr/local/bin/deploy-app` |
| project | `scripts/add-project.sh` | `/opt/<app>`, `.env` ownership, deployer key for `deploy-app <app>`, repository secrets on the forge |

Both init scripts and `vpn-deploy` live in `${CLAUDE_SKILL_DIR}/bin/`: run
them by that path, it works for the plugin and for a skill directory in
`~/.claude/skills`. With the plugin enabled they are also bare commands on the
Bash tool PATH. They are idempotent and take no password prompts except the
root password of `vps-init` on a fresh server.

Personal values live in one file `~/.config/devops/env` (`KEY=value`,
sourced, chmod 600), template `env.example`: `DEVOPS_ADMIN` (required),
`DEVOPS_PUBKEY_FILE` (default `~/.ssh/id_ed25519.pub`), `DEVOPS_IGNOREIP`
(fail2ban, besides loopback), `DEVOPS_TZ` (empty = zone unchanged),
`DEVOPS_ACME_EMAIL` (web-init), `DEVOPS_FORGE` (`forgejo` by default, or
`github`: CI template and how add-project.sh sets secrets),
`DEVOPS_REGISTRY` (Forgejo host; not used with `github`, the registry there is
`ghcr.io`), `DEVOPS_REGISTRY_USER` (fallback owner when the project has no git
remote), `DEVOPS_REGISTRY_LOGIN` (registry login, a real user; default
`DEVOPS_REGISTRY_USER`) and `DEVOPS_FORGEJO_TOKEN_CMD` (command printing the
Forgejo API token from the keychain). An environment variable of the same
name wins over the file; `DEVOPS_CONFIG` points to another file. A missing
required key stops the script with the key name and the file path.

For VLESS, a VPN server goes through `vpn-deploy`, not `web-init`. It runs `vps-init`,
then installs xray and removes the 04:00 auto-reboot that `vps-init` set
before xray existed. It records a fingerprint of `vps-init` and its settings
on the server, then skips that step on reruns while the fingerprint matches.
For older deployments, it records completion once when it finds an existing
Xray client config. It checks Xray dependencies and installs only missing
packages.

## AmneziaWG alongside VLESS

For an Ubuntu 24.04 x86-64 VPN node already prepared with `vps-init`,
`bin/awg-deploy <IPv4>` installs AmneziaWG 3.1 alongside Xray. It requires
Go 1.25 or newer and Git on the local machine and uses TCP SSH, UDP 51820,
IPv4 subnet 10.77.0.0/24 and the server's default outbound interface. It
stops if another AWG installation or the UDP port is already in use; it
does not migrate existing AWG servers or their clients. It creates one
client and reuses it on a rerun. The server uses the pinned official
userspace implementation and tools, with IPv4 forwarding and NAT.

The output directory `~/vpn-configs/<IP>/amneziawg/` contains
`user-01.conf` for compatible native clients and `user-01.vpn` for
AmneziaVPN. Prefer the `.vpn` key for AmneziaVPN: in the verified 5.0.3
macOS installation, importing `.conf` lost the 3.1 header protection and
padding parameters, preventing the handshake. Generate the `.vpn` with
`scripts/awg-link.py`; it is a credential and must stay private. A new
client app does not upgrade existing 2.0 servers: never remove or upgrade
an existing protocol or reissue another server's users without an explicit
migration request. Check the actual tunnel from a separate device or network;
`systemctl is-active` and a listening UDP port do not prove connectivity.

## Add VPN users

On a node with Xray and the AmneziaWG setup above, run:

```bash
bin/vpn-users <IP or SSH alias> <count>
```

`count` is the number of new users, not the final total. The command uses
`DEVOPS_ADMIN` for SSH and `sudo -n` for server changes. It allocates a
separate VLESS UUID and an AmneziaWG key and address for each user. It does
not restart either service. Existing users and profiles are kept. The
command prints a ready-to-run SSH command to download one `.tar.gz` archive.
The archive has a directory per user containing `vless.txt`, `vless.png`,
`amneziawg.conf` and `amneziawg.vpn`. Use `.vpn` in AmneziaVPN. The server
keeps the archive under `/var/lib/vpn-users/exports/`, owned by root with
mode 600. Treat the archive and extracted files as credentials. Delete the
archive after distribution when it is no longer needed. The command uses an
exclusive lock and rolls back newly created users on a reported error. If a
rollback reports a failure, inspect both services before retrying.

## 1. Check the server

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/check.sh <IP or alias>
```

The last line is for parsing. The exit code: 0 state read, 1 an installed
layer is broken, 2 no connection. `WARN` lines do not count in `FAIL` and do
not stop the run: show them to the user next to the next step.

| Last line | Next step |
|-----------|-----------|
| `LAYER=none ROOT_KEY=no` | open items block: the user runs `vps-init` in a terminal |
| `LAYER=none ROOT_KEY=yes` or `LAYER=none FAIL=0 …` | run `vps-init <IP> <name>` |
| `LAYER=vps FAIL=0 …` | run `web-init <alias>` |
| `LAYER=web FAIL=0 PROJECTS=…` | step 2; `<app>` in `PROJECTS` means already deployed: changes go by push |
| `FAIL=<n>` with n > 0 | show the FAIL lines, stop. Rerunning the init script of that layer repairs its contract; a public port or a mounted socket is fixed in the project that owns the container |

Run `check.sh` again after each layer. Read `.devops-config` if the project
has one (`references/config-schema.md`), otherwise write it. Do not ask the
user for the repository: take it from `git remote get-url origin` (owner and
name can change after a transfer, and the name may differ from `app`):

```bash
. ${CLAUDE_SKILL_DIR}/lib/config.sh && devops_repo . && echo "$DEVOPS_REPO_OWNER/$DEVOPS_REPO_NAME on $DEVOPS_REPO_HOST"
```

Update `repo` in `.devops-config` when it differs from the remote.

## 1a. Check the forge

Run this in the project directory before you ask the user anything about the
forge (repository, token, runner, secrets, variables, image):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/forge-check.sh [project dir] [app]
```

It computes the state on every run from the forge API (GET only; Forgejo
with the API token, GitHub with `gh`) and stores nothing. Exit code 0: the
last line is printed. Exit code 2: usage error, missing setting, or the forge
does not answer. Last line, one `KEY=value` per field, no spaces in values,
lists comma-separated:

```
FORGE=forgejo HOST=git.example.com OWNER=acme OWNER_TYPE=org REPO=shop APP=shop
IMAGE_REF=git.example.com/acme/shop TOKEN=ok REPO_STATE=exists WORKFLOW=project
RUNNER=online RUNS_WAITING=0 SECRETS=DEPLOY_HOST,... VARS=REGISTRY MISSING= UNKNOWN= IMAGE=present
```

(one line in the real output). Required names are the `secrets.X` and
`vars.X` that the project workflow reads (`WORKFLOW=project`), else those of
the CI template (`WORKFLOW=template`). A name at the owner level
(organization or user) counts for every repository of the owner.

| Key | Next step |
|-----|-----------|
| `TOKEN=missing` or `bad` | the other facts are `unknown`: ask for the token first (open items, step 4), then run again |
| `REPO_STATE=missing` | create the repository (`references/forgejo-actions.md`) |
| `MISSING=<names>` | exactly these go to add-project.sh or the open items; names not listed exist |
| `UNKNOWN=<names>` | not in the repository and the owner level is not readable (Forgejo user secrets, organization lists without owner rights): ask the user whether they exist at the owner level |
| `RUNNER=offline`, `none` | open item: register or start a runner with the labels of `runs-on`, with the runner prerequisites of `references/forgejo-actions.md` |
| `RUNS_WAITING` > 0 with `RUNNER` not `online` | the pipeline is stuck: no runner takes the jobs |
| `IMAGE=absent` | normal before the first green run on `main` |

`IMAGE_REF` is the image that `/opt/<app>/.env` on the server must name in
`IMAGE`: compare it with the server when a repository moved to another owner.

## 2. Prepare the project repository

Adapt the templates in `assets/` to the stack, do not copy them blindly:

- `assets/compose.yml` → `docker-compose.yml`: environment, migrate command,
  healthcheck, port, optional redis (`references/docker-traefik.md`);
- `assets/.env.example` → `.env.example` with the project variables;
- the CI template of `DEVOPS_FORGE`, only the `test` job changes:
  `forgejo` → `assets/.forgejo/workflows/ci.yml` to `.forgejo/workflows/ci.yml`
  (`references/forgejo-actions.md`; reads the repository variable `REGISTRY`;
  the `test` job needs the runner prerequisites from there: the CI image
  `assets/ci-image/Dockerfile` built on the runner host and the uv cache in
  `valid_volumes`);
  `github` → `assets/.github/workflows/ci.yml` to `.github/workflows/ci.yml`
  (`references/github-actions.md`; image `ghcr.io/<owner>/<repo>`);
- Dockerfile: non-root user with a fixed UID, and
  `COPY docker-compose.yml /app/docker-compose.yml` — the deploy script reads
  the compose file from the image; every `FROM` and `COPY --from` image is
  `name:tag@sha256:<digest>` (the Digest of
  `docker buildx imagetools inspect <name:tag>`), else BuildKit asks the
  registry on every build, and a stale login there fails it; no
  `# syntax=` line (it pulls the frontend image); uv and pip download into
  `RUN --mount=type=cache,target=/root/.cache/uv` with `ENV UV_LINK_MODE=copy`;
- `.gitignore`: `.env`.

Validate: `IMAGE=<registry>/<owner>/<app> docker compose --env-file <dummy env> config -q`
(deploy-app passes `IMAGE` in the environment), `actionlint`, and
`bash ${CLAUDE_SKILL_DIR}/scripts/dockerfile-pins.sh Dockerfile` (prints
the lines without a digest pin).

## 3. Prepare the server

The skill never runs `docker compose up` on the server: the only path to
production is CI. One script deploys every project: `web-init` installs
`/usr/local/bin/deploy-app` (root:root 755) from `assets/deploy-app`, and
reruns replace it when the file in the skill changes.

```bash
# in the project directory: the repository comes from its git remote
bash ${CLAUDE_SKILL_DIR}/scripts/add-project.sh <host> <app>
# Forgejo token: DEVOPS_FORGEJO_TOKEN_CMD (keychain) or FORGEJO_API_TOKEN
# DEVOPS_FORGE=github: no token, gh must be logged in (gh auth status)
```

`add-project.sh` is idempotent and does:

- `/opt/<app>` `root:root 755`, `state/` inside it `deployer:deployer 755`:
  the only place deployer writes (`last-known-good`, `deploy.log`,
  `deploy.lock`, `pre-deploy.sql.gz`, registry login in `docker/`);
- ownership `root:deployer 640` on `/opt/<app>/.env` when it is there. It
  does not create the file: the user sends it over ssh stdin
  (`sudo install -m 640 -o root -g deployer /dev/stdin /opt/<app>/.env`),
  the secrets-keeper skill generates the values that can be generated.
  A file recreated by hand (`nano`, `cp`) drifts to 644; `check.sh` prints
  a WARN with the `chown`/`chmod` that restores it;
- a fresh ed25519 key, one line per project in
  `/home/deployer/.ssh/authorized_keys`, found by its comment:
  `restrict,command="/usr/local/bin/deploy-app <app>" ssh-ed25519 AAAA… <app>-deploy@<forge>`.
  An existing line is kept; to rotate, delete it and run again;
- the secrets `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_HOST_KEY`, then the
  private key is deleted. The repository is `<owner>/<name>` of the git
  remote (`references/config-schema.md`, "Owner and repository").
  Forgejo: with the API token (`FORGEJO_API_TOKEN`, else the output of
  `DEVOPS_FORGEJO_TOKEN_CMD`; scopes `write:repository` and
  `write:organization`; `FORGEJO_REPO` overrides the repository), also the
  repository variable `REGISTRY` = `DEVOPS_REGISTRY`, and `REGISTRY_USER` =
  `DEVOPS_REGISTRY_LOGIN` when the owner is an organization. A failing token
  command stops the run with the `security add-generic-password` line to
  store the token. GitHub: with `gh secret set` when `gh auth status`
  succeeds (`GITHUB_REPO` overrides the repository). An owner other than the
  login also needs `REGISTRY_USER=<login>` in `/opt/<app>/.env`, an open
  item when it is missing. Without the token or `gh` the key stays in a
  temporary directory, and the open items give the paste or `gh` commands
  and the delete command;
- prints `DONE <app>@<host>`, or the open items under `Waiting for you:`
  followed by `WAIT <n>` (step 4).

Ownership rule: `/home/deployer`, `/home/deployer/.ssh` are `root:root 755`,
`authorized_keys` is `root:root 644`. The owner of a directory can rename or
delete any file in it, so a deployer-owned `.ssh` would let a leaked key
replace its own forced command. `web-init` sets this, `check.sh` asserts it.

What `deploy-app <app>` does on `ssh deployer@<host> "deploy <sha>"`:

- accepts exactly `deploy <40-hex>`, logs and refuses anything else;
- takes `flock -n` on `state/deploy.lock`: a second rollout of the same
  project fails at once;
- reads `IMAGE` (required, `<registry>/<owner>/<app>`), `REGISTRY_TOKEN`
  (required), `REGISTRY_USER` (default the `<owner>` of `IMAGE`) from `.env`;
  `add-project.sh` lists a missing `IMAGE` among the open items; logs in to the registry of `IMAGE`, pulls the tag
  and resolves it to an image ID; the other images of the stack are pulled
  only when missing (`compose pull --policy missing`): a third-party image
  changes only when its tag or digest in the compose file changes;
- reads the compose file once from that image ID (`/app/docker-compose.yml`,
  fallback `/opt/<app>/docker-compose.yml`) and gives the same bytes to every
  compose call, passes `IMAGE` and `IMAGE_TAG` in the environment, project
  name `<app>`;
- before the first compose call, loads the raw compose with python3 and
  PyYAML and refuses `include`, `extends.file`, `label_file` and `build`:
  compose would read those files (another project's `.env` included)
  while it parses;
- renders that compose with `docker compose config --format json
  --no-env-resolution` and checks it with `jq` before the dump and `up`:
  `env_file` outside `/opt/<app>/`, `use_api_socket`, `provider`, published
  `ports` (one finding per port, `<svc>.ports:<ip>:<published>:<target>/<proto>`;
  Docker bypasses ufw), privileged, host or `container:`
  namespaces, `cap_add`, `devices`, unconfined `security_opt`, binds that are
  not a direct child of `/opt/<app>/` or are a symlink (the Docker socket,
  deeper paths, `state/` included), foreign or external volumes and networks
  (except `proxy`; a name `<app>_x_*` while a project `<app>_x` exists is
  foreign too), `secrets`/`configs` files by the same rule stop the
  rollout with the findings named; after `compose pull` the tag must still
  name the checked image ID; Traefik labels of each service (image labels
  included) may name only `<app>`/`<app>-*` routers, services and
  middlewares and route only `Host`s in `SITE_DOMAIN` and `ALLOWED_HOSTS`
  of `.env`, joined with `&&` (no `||`, `!`, `HostRegexp`); `up` runs with
  `--pull never --no-build` and `state/compose-pin.json`, every service
  pinned to its checked image ID; exceptions are lines in the
  root-owned `/opt/<app>/compose-policy-allow`
  (references/security-checklist.md);
- if the running stack has a `postgres` service: `pg_dump` of every
  non-template database of its cluster, each after a `\connect`, into
  `state/pre-deploy.sql.gz`, one file overwritten by each rollout; a failed
  dump of any database stops the rollout. First deploy: skipped with a log
  line;
- `up -d --remove-orphans --wait`; healthy → the tag goes to
  `state/last-known-good`, `docker image prune`; not healthy → logs and
  rollback to `last-known-good`, pulled explicitly and checked the same way
  first, or the run stops with "needs a human";
- copies its output to `state/deploy.log`.

Tests: `scripts/deploy-app_test.sh` (parsing, lock, pre-deploy dump,
compose policy; runs as root in a throwaway debian container),
`scripts/migrate_test.sh` (the Alembic
migrate command against SQLite, in a python container),
`scripts/config_test.sh` (`~/.config/devops/env` loading and missing keys),
`scripts/add-project_test.sh` (both forges with ssh, gh and curl shims, no
server),
`scripts/forge-check_test.sh` (both forges with curl and gh shims answering
from fixtures, no forge),
`scripts/dockerfile-pins_test.sh` (sample Dockerfiles),
`scripts/integration_test.sh` (vps-init + web-init +
add-project.sh + real rollouts in a local systemd container, ~10 min),
`scripts/integration_vpn_test.sh` (vpn-deploy on a fresh container
without the web layer, ~3 min). Both share `scripts/integration_lib.sh`
and run one after another: a parallel run once failed vpn-deploy.

## 4. What the skill cannot do itself

Collect every open item into one block, print it in the user's language,
and stop. English template:

```
Waiting for you:
1. Run in a terminal: ! ${CLAUDE_SKILL_DIR}/bin/vps-init <IP> <name>. Root has no key, so vps-init asks for the password.
   When ordering a VPS, add your SSH key for root: then I can run vps-init myself.
2. DNS A record <domain> → <IP>. I will check: dig +short <domain>.
3. Forgejo tokens (Settings → Applications): read:package for the server,
   write:package for CI, write:repository for the API, if missing.
   GitHub: a classic token with read:packages for the server, `gh auth login`.
4. .env values that cannot be generated: <name>: <where to get it>.
```

Only the items that are open go into the block. Continue after the user answers.

The DNS gate is strict: `dig +short <domain>` must print the server IP
before the first deploy. Otherwise Traefik asks Let's Encrypt for a
certificate it cannot get, and repeated failures hit the rate limit.

## 5. First deploy

Push to `main`. CI tests, builds, pushes the image, and calls the deploy
script. After a green run:

- `check.sh <host>` lists `<app>` in `PROJECTS` with `FAIL=0`;
- `curl -sI https://<domain>` answers with a valid certificate;
- `nmap -Pn --top-ports 1000 <IP>` from outside shows 22, 80, 443 only.

## Migrations

They run in the `migrate` service on every deploy. A migration must work with
the previous image: auto-rollback restores the image, not the schema. The
previous image runs its `migrate` again on the newer schema, so the command
must exit 0 on a database ahead of the image: for Alembic, the `sh -c`
wrapper of `assets/compose.yml` (`alembic upgrade head` alone fails with
"Can't locate revision" and the rollback does not come up).
deploy-app keeps one dump of every database of the cluster from just before
the last rollout in `/opt/<app>/state/pre-deploy.sql.gz`. It is not a backup:
one copy on the same disk. Details:
`references/migration-patterns.md`.

## References

- `references/docker-traefik.md`: server Traefik stack, networks, project stack rules
- `references/forgejo-actions.md`: pipeline, runner quirks, secrets through the API
- `references/github-actions.md`: GitHub template, GHCR tokens, package visibility
- `references/migration-patterns.md`: migrate service, compatibility rule, rollback past a migration, the dump, commands per stack
- `references/security-checklist.md`: published ports, external scan, container hardening
- `references/config-schema.md`: `.devops-config`
