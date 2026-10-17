# Security Beyond the Init Scripts

`vps-init` and `web-init` already set up sshd, ufw, fail2ban, automatic
updates with a reboot at 04:00 (none on a VPN node), the Docker log ceiling,
socket-proxy for Traefik and an unprivileged `deployer`. `scripts/check.sh` asserts all of that. This file covers only
what the scripts do not do.

## Published ports bypass ufw

Docker writes its own iptables rules: `ports: ["5432:5432"]` is reachable from
the internet while `ufw status` reports `deny incoming`. In a project compose
there are no `ports:` at all; `check.sh` fails on any container except Traefik
that publishes on `0.0.0.0` or `[::]`.

When a port must be published (a debug tool, a non-HTTP service):

```yaml
    ports:
      - "127.0.0.1:5432:5432"   # loopback only, reach it with ssh -L
```

A port that must be public but only for some sources is filtered in the
`DOCKER-USER` chain. The chain runs after DNAT, so match the original
destination port, not the container port, or a mapping like `5433:5432` slips
through. Docker flushes the chain on daemon restart: persist the rule with
`iptables-persistent` or a systemd unit.

```bash
sudo iptables -I DOCKER-USER -i eth0 \
  -m conntrack --ctorigdstport 5432 --ctdir ORIGINAL -j DROP
```

## Check from outside

The host sees its own loopback and cannot tell what the internet sees. After
the first deploy and after every change to ports, scan from another machine:

```bash
nmap -Pn -sV --top-ports 1000 <server-ip>     # expected: 22, 80, 443
```

## Container hardening

The project template (`assets/compose.yml`) carries these; keep them when
adapting:

- `read_only: true` with `tmpfs: [/tmp]`: nothing is written into the
  container layer. A volume only where the service stores data (postgres).
- `security_opt: [no-new-privileges:true]`: setuid binaries in the image do not
  raise privileges.
- Non-root user with a fixed UID in the Dockerfile:

  ```dockerfile
  RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
  USER 10001
  ```

  Check on the server: `docker exec <app>-app-1 id -u` must not print `0`.
- No Docker socket in any project container. A tool that needs the Docker API
  goes through socket-proxy with the minimum of allowed sections.

## The compose policy of deploy-app

`deployer` is in the `docker` group, and the compose file comes from the
image, so whoever can push to main decides what runs as root on a server
shared with other projects. `deploy-app` checks the stack of the tag in
three steps before the dump and `up`, and again before a rollback.

Files outside the image. Compose reads the files named by `include`,
`extends.file` and `label_file` while it parses, whatever `--no-*` flags
`config` gets, and inlines them; `env_file` too unless
`--no-env-resolution`. Every `/opt/*/.env` is readable by `deployer`, so a
compose with `env_file: /opt/other/.env` would get another project's
secrets. Before the first compose call, `deploy-app` loads the raw file with
python3 and PyYAML (web-init installs `python3-yaml`) and refuses `include`,
`extends` with `file`, `label_file` and `build` (it pulls and never builds);
no allow file entry lifts this. YAML that PyYAML and Compose could read
differently is refused too: explicit tags, several documents, U+0085,
U+2028, U+2029.

The rendered stack. `docker compose config --format json
--no-env-resolution` is checked with `jq`; it refuses `privileged`, a host or
`container:` namespace (`network_mode`, `pid`, `ipc`, `uts`, `cgroup`,
`userns_mode`), `cap_add`, `devices`, `device_cgroup_rules`, an
`unconfined` `security_opt`, `volumes_from` another container, a bind mount
whose source is not a direct child of `/opt/<app>/` (the Docker socket,
deeper paths and `..` included), is `state/` or the allow file, or is a
symlink on disk, a named volume or network that is external, carries
`driver_opts` or another project's name (the shared `proxy` network
excepted), `secrets`/`configs` files and `env_file` paths by the same rule
as binds, `use_api_socket`, `provider` (a program compose runs on the host),
`build`, a service without `image`, and any published port in `ports`.
Docker writes its own iptables rules for a published port, so ufw does not
stop `5432:5432` from reaching the internet; Traefik is the only way in.
A port finding is `<svc>.ports:<ip>:<published>:<target>/<protocol>`, one
per port (compose renders a range port by port), `*` for every interface or
a random host port, IPv6 in brackets: `postgres.ports:*:5432:5432/tcp`,
`app.ports:127.0.0.1:8080:80/tcp`. An exception covers that one port.
`expose` publishes nothing and passes. The refusal names each finding, such
as `app.cap_add`; the production stack stays as it was. A previous tag that
fails the policy is not rolled back to.

Traefik labels. One Traefik routes every project, so a router for another
project's host would take its traffic and request its certificate. After
`compose pull`, `deploy-app` checks the labels of each service: those of
its image (Docker copies them onto the container, Traefik reads them there)
with the compose labels over them, keys in lower case. It refuses
(`<svc>.labels:<key>`):

- router, service and middleware names other than `<app>` or `<app>-*`,
  or `<other>-*` of a project `/opt/<other>` named `<app>-*`;
- a rule that is not matchers joined by `&&` with at least one `Host` or
  `HostSNI`: no `||`, no `!`, no `HostRegexp`; the other matchers allowed
  are `Path`, `PathPrefix`, `PathRegexp`, `Method`, `Header`,
  `HeaderRegexp`, `Query`, `QueryRegexp`, `ClientIP`, `ALPN`;
- a host in a rule or in `tls.domains[n].main`/`.sans` that is not
  `SITE_DOMAIN` or in `ALLOWED_HOSTS` of `/opt/<app>/.env`;
- a router without a rule, `traefik.enable=true` without a router (both
  get Traefik's default rule), a router service that is not the project's
  (`api@internal`), a udp router, any other key under `traefik.`.

A project with several hosts lists them in `ALLOWED_HOSTS`:

```bash
echo 'ALLOWED_HOSTS=www.example.com,api.example.com' | sudo tee -a /opt/<app>/.env
```

Why direct children only: root in a container is root on the host, so below
a bound directory a container can plant a symlink, and the next rollout that
binds that path mounts the symlink target from the host. `/opt/<app>` is
`root:root 755` and never bound, so no container can create or swap an entry
in it, and a direct child that is not a symlink at the check stays so until
`up`. Bind `./uploads`, not `./data/uploads`.

Names that collide through `_`: compose names volumes and networks
`<app>_<name>`, so volume `x_data` of `demo` and volume `data` of `demo_x`
are both `demo_x_data`. `deploy-app` of `demo` refuses a volume or network
named `demo_x_*` while `/opt/demo_x` exists, and `add-project.sh` refuses a
new project `demo_x` next to `demo`, or `demo` next to `demo_x`.

The checked compose is the started one. `deploy-app` resolves the tag to an
image ID after `docker pull`, reads the compose file from that ID once, and
gives the same bytes to `config`, `pull` and `up`. After `compose pull` the
tag must still name that ID: a tag pushed again in the meantime (the CI
token writes to the registry) stops the run with "production untouched".
Every image of the stack is then resolved to its ID, and `up --pull never
--no-build` gets `state/compose-pin.json`, which sets each service's image
to that ID: a tag moved on the server after the check (another project
pulling the same reference) changes nothing. `docker ps` shows these
containers with an image ID. The rollback pulls the previous tag explicitly
and goes the same way.

An exception (rendered stack, Traefik labels) is a line in
`/opt/<app>/compose-policy-allow` with the finding exactly as the refusal
prints it; `#` starts a comment. Only root writes the
file: `deploy-app` stops when it is not a regular file of root or is writable
by group or others. An exception for a deeper bind brings the symlink case
back for that path.

```bash
echo 'socket-proxy.volumes:/var/run/docker.sock  # read-only API for the tool' \
  | sudo tee -a /opt/<app>/compose-policy-allow
echo 'app.ports:127.0.0.1:8080:80/tcp  # admin over an SSH tunnel' \
  | sudo tee -a /opt/<app>/compose-policy-allow
sudo chmod 644 /opt/<app>/compose-policy-allow
```
