# devops: a Claude Code plugin for VPS deploys

The plugin gives Claude Code one skill, `devops`, and three shell scripts in
`bin/`, plus helper scripts in `skills/devops/scripts/`.
Together they take a fresh Ubuntu VPS to a server that runs your projects
behind Traefik. CI deploys each project over SSH.

The server is built in layers. Each layer has its own idempotent script.

| Layer | Script | What it sets up |
|-------|--------|-----------------|
| `vps` | `vps-init <IP> [name]` | Admin user with your key and sudo, root login closed, passwords off, ufw with port 22, fail2ban, unattended upgrades with a reboot at 04:00, BBR, swap, journal limit, optional time zone, a `Host` alias in `~/.ssh/config` |
| `web` | `web-init <IP or alias>` | Docker CE with container logs in journald (30 days, survive redeploys), the Traefik stack in `/opt/traefik` with a Docker socket proxy, network `proxy`, ufw 80/443, user `deployer`, `/usr/local/bin/deploy-app`, weekly image prune |
| project | `skills/devops/scripts/add-project.sh <host> <app>` | `/opt/<app>`, ownership of its `.env`, a deploy key bound to `deploy-app <app>`, repository secrets on Forgejo or GitHub |

The first deploy is the first CI run. CI builds the image, pushes it to the
registry, and calls `deploy-app` on the server. `deploy-app` pulls the image,
dumps the Postgres databases of the running stack, starts the new version, and
rolls back to the last healthy tag if a health check fails.

A VPN server takes another path. `vpn-deploy <IP> <clients>` runs `vps-init`,
installs xray with VLESS Reality, creates the clients, and downloads their
links and QR codes to `~/vpn-configs/<IP>`. A VPN server gets no web layer and
no automatic reboot.

`skills/devops/scripts/check.sh <host>` reads which layers a server has and
whether they still hold. The skill uses its last line to pick the next step.

`skills/devops/scripts/forge-check.sh [project dir] [app]` reads what the
forge already holds for a project: the repository, the API token, an online
runner, runs waiting for a runner, the secrets and variables that the CI
workflow reads (at the repository or the owner level), and the image in the
registry. It sends only GET requests. Its last line lists the missing names,
so the skill asks only for those.

## Requirements

- Client: macOS or Linux with bash, ssh, ssh-keygen, curl and python3.
- Forgejo as the forge: a Forgejo instance with Actions and its container
  registry, and an API token with scope `write:repository`. The Forgejo
  runner host needs the CI image and the uv cache volume once (runner
  prerequisites in `skills/devops/references/forgejo-actions.md`).
- GitHub as the forge: the `gh` CLI, logged in. Images go to GHCR.
- Server: Ubuntu 22.04 or 24.04, reachable as root over SSH for the first
  `vps-init` run.
- Tests: Docker on the client.

## Install

Add this repository as a marketplace, then install the plugin:

```text
/plugin marketplace add AzretMagometov/claude-devops-plugin
/plugin install devops@devops-vps
```

The same from a shell:

```bash
claude plugin marketplace add AzretMagometov/claude-devops-plugin
claude plugin install devops@devops-vps
```

A marketplace added from a GitHub repository is copied into
`~/.claude/plugins/cache/`, one directory per version. To work from a clone
instead, add the clone by its path. Claude Code then loads the plugin in place:

```bash
git clone https://github.com/AzretMagometov/claude-devops-plugin.git ~/src/claude-devops-plugin
claude plugin marketplace add ~/src/claude-devops-plugin
claude plugin install devops@devops-vps
```

Install the skill one way only. A copy of `skills/devops` in
`~/.claude/skills/` and the plugin together give Claude two `devops` skills.

## Putting the scripts on PATH

The plugin has a `bin/` directory. While the plugin is enabled, Claude Code
puts it on the PATH of its Bash tool, so Claude runs `vps-init`, `web-init`
and `vpn-deploy` as bare commands.

Your own terminal does not get that PATH. Link the scripts from a clone into a
directory on your PATH, for example `~/.local/bin`:

```bash
for s in vps-init web-init vpn-deploy; do
  ln -sf ~/src/claude-devops-plugin/skills/devops/bin/$s ~/.local/bin/$s
done
```

Link to a clone, not to the plugin cache: the cache path changes with each
version. The scripts follow their own symlinks to find `lib/` and `assets/`.

## Configuration

Personal values live in one file, `~/.config/devops/env`. Every script sources
it. Start from the template and keep the file private:

```bash
mkdir -p ~/.config/devops
cp skills/devops/env.example ~/.config/devops/env
chmod 600 ~/.config/devops/env
```

| Key | Default | Meaning |
|-----|---------|---------|
| `DEVOPS_ADMIN` | required | Admin user that `vps-init` creates. All scripts log in as this user. |
| `DEVOPS_PUBKEY_FILE` | `~/.ssh/id_ed25519.pub` | Public key for the admin's `authorized_keys`. |
| `DEVOPS_IGNOREIP` | empty | Addresses that fail2ban never bans, besides loopback: your other servers, your home IP. |
| `DEVOPS_TZ` | empty | Server time zone for `vps-init`. Empty leaves the zone unchanged. |
| `DEVOPS_ACME_EMAIL` | none | Let's Encrypt account address for `web-init`. An argument overrides it. |
| `DEVOPS_FORGE` | `forgejo` | `forgejo` or `github`. Picks the CI template and how `add-project.sh` sets secrets. |
| `DEVOPS_REGISTRY` | none | Forgejo host: container registry and API. Not used with `github`, which always uses `ghcr.io`. |
| `DEVOPS_REGISTRY_USER` | none | Fallback owner of the repositories and images when the project has no git remote. Scripts take the owner (user or organization) from `git remote get-url origin` first. |
| `DEVOPS_REGISTRY_LOGIN` | `DEVOPS_REGISTRY_USER` | Registry login, a real user: an organization owns images but cannot log in. |
| `DEVOPS_FORGEJO_TOKEN_CMD` | none | Command that prints the Forgejo API token, e.g. `security find-generic-password -s devops-forgejo -a ops -w`. Scopes `write:repository` and `write:organization`. `FORGEJO_API_TOKEN` in the environment wins. |

An environment variable with the same name wins over the file.
`DEVOPS_CONFIG` points the scripts to another file. A missing required key
stops the script before any SSH connection. The error names the key and the
file.

## Quick start

Ask Claude in your project: "here is a server 203.0.113.5, deploy this project
to app.example.com". The skill then runs the steps below. You can also run
them by hand.

1. Check the server. The last line tells you the next step.

   ```bash
   bash skills/devops/scripts/check.sh 203.0.113.5
   ```

2. Build the layers. `vps-init` asks for the root password if root has no key.

   ```bash
   vps-init 203.0.113.5 web1
   web-init web1
   ```

3. Prepare the project repository from the templates in
   `skills/devops/assets/`: `compose.yml`, `.env.example`, the CI workflow of
   your forge, a Dockerfile that copies `docker-compose.yml` into the image.

4. Prepare the server for the project. Send the project `.env` over SSH stdin
   to `/opt/<app>/.env` first.

   Run it in the project directory: the repository comes from its git
   remote. With Forgejo (`DEVOPS_FORGE=forgejo`), store the API token in the
   keychain once and point `DEVOPS_FORGEJO_TOKEN_CMD` at it:

   ```bash
   security add-generic-password -s devops-forgejo -a ops -w
   bash <plugin>/skills/devops/scripts/add-project.sh web1 myapp
   ```

   With GitHub (`DEVOPS_FORGE=github`, `gh auth status` succeeds):

   ```bash
   bash <plugin>/skills/devops/scripts/add-project.sh web1 myapp
   ```

5. Point the DNS A record of the domain to the server IP. Check it with
   `dig +short app.example.com` before the first deploy.

6. Push to `main`. CI tests, builds, pushes the image and deploys it.

The skill text in `skills/devops/SKILL.md` and the files in
`skills/devops/references/` cover each step in detail.

## Tests

Run the tests from the repository root. They never read
`~/.config/devops/env`: each test sets its own values.

```bash
bash skills/devops/scripts/config_test.sh        # config loading, missing keys
bash skills/devops/scripts/check_test.sh         # layer logic of check.sh
bash skills/devops/scripts/add-project_test.sh   # both forges, with shims, no server
bash skills/devops/scripts/deploy-app_test.sh    # deploy-app in a Debian container, installs jq and python3-yaml there
bash skills/devops/scripts/migrate_test.sh       # Alembic migrate command in a Python container
bash skills/devops/scripts/integration_test.sh   # vps-init, web-init, add-project.sh, real rollouts, ~10 min
bash skills/devops/scripts/integration_vpn_test.sh  # vpn-deploy on a fresh container, ~3 min
```

The integration tests start a privileged Ubuntu container with systemd. They
never touch `~/.ssh/config`. Run them one after another, not in parallel.

GitHub Actions (`.github/workflows/test.yml`) runs shellcheck on every shell
script, validates `.claude-plugin/*.json` and runs all tests except the
integration tests on each push to `main` and each pull request.

## Security notes

The scripts change the server as root through sudo. Read them before you run
them against a server that already holds data.

- `vps-init` creates the admin user with passwordless sudo and closes root
  login. It closes root only after a key login as the admin works.
- `vps-init` turns off SSH passwords, limits SSH logins with `AllowUsers`,
  and enables ufw with port 22 only. `web-init` adds `deployer` to that list.
- `vps-init` turns on unattended upgrades with a reboot at 04:00. A server
  with xray gets no automatic reboot, because a reboot drops the tunnels.
- `web-init` installs Docker from the official repository and opens ports
  80 and 443. Traefik reads Docker through a socket proxy, not the socket.
- `deployer` has no sudo and no password. Each project key in its
  `authorized_keys` is `restrict` and runs one forced command:
  `deploy-app <app>`. Its `~/.ssh` belongs to root, so a leaked key cannot
  replace its own forced command.
- `deploy-app` accepts only `deploy <40-hex sha>` and refuses other input.
- `deploy-app` checks the compose file of the tag before it changes
  production and before a rollback. It refuses privileged containers, host
  namespaces, added capabilities and devices, unconfined seccomp or
  AppArmor, the Docker socket, bind mounts other than a direct child of
  `/opt/<app>/` that is not a symlink, `env_file` by the same rule, the
  Docker API socket option, published `ports` (Docker opens them past ufw),
  and volumes or networks of other projects.
  Root grants exceptions in `/opt/<app>/compose-policy-allow`
  ([security-checklist.md](skills/devops/references/security-checklist.md)).
- `deploy-app` refuses `include`, `extends` from a file, `label_file` and
  `build` before compose reads the file: compose would read those files
  with deployer's rights, and deployer can read the `.env` of every project.
- `deploy-app` refuses Traefik labels, of the compose file or of the image,
  that route a host other than `SITE_DOMAIN` and `ALLOWED_HOSTS` of the
  project's `.env`, use `||`, `!` or `HostRegexp`, or name a router,
  service or middleware outside `<app>` and `<app>-*`.
- `deploy-app` resolves the tag to an image ID once, reads the compose file
  from that ID once, and starts every service from the image ID it checked,
  with `--pull never`. A tag pushed again to the registry during the
  rollout stops the run.
- Compose names volumes and networks `<app>_<name>`, so volume `x_data` of
  `demo` is volume `data` of `demo_x`. `add-project.sh` refuses a project
  whose name extends another one on the server with `_`, or the reverse, and
  `deploy-app` refuses such names while the longer project exists.

### Trust model

Several projects, possibly of different clients, share one web server. A
push to the main branch of a project can change only that project: the
compose policy of `deploy-app` stops a pushed compose file from reaching the
host or another project through the keys above, through files of other
projects or through Traefik routes to their hosts, and from publishing a
port on the host: Docker writes its own iptables rules, so ufw does not stop
a published postgres from reaching the internet. The policy does not limit
the application code. That code runs with its own secrets and its own
database, and it reaches whatever its network allows. The policy also does
not cover a kernel or Docker escape. Keep projects with different trust
levels on separate VPS when you need strong isolation.
- `add-project.sh` deletes the local copy of the private deploy key after it
  uploads the key as a repository secret.
- `vpn-deploy` writes client links to `~/vpn-configs/<IP>` on your machine
  with mode 700. Treat them as credentials.

## Contributing

The repository has a pre-commit hook that runs gitleaks over the staged
changes. It also greps them against a private marker list outside the
repository: `~/.config/devops/private-markers`, one extended regex per line,
case-insensitive. Put strings there that must never reach a public commit:
your hostnames, IPs, e-mail addresses. Without the list, only gitleaks runs.

```bash
git config core.hooksPath .githooks
bash .githooks/pre-commit_test.sh
```

## License

MIT, see [LICENSE](LICENSE).
