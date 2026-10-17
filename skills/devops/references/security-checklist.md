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
shared with other projects. `deploy-app` renders the stack of the tag with
`docker compose config --format json` before the dump and `up`, and again
before a rollback, and refuses it with `privileged`, a host or
`container:` namespace (`network_mode`, `pid`, `ipc`, `uts`, `cgroup`,
`userns_mode`), `cap_add`, `devices`, `device_cgroup_rules`, an
`unconfined` `security_opt`, `volumes_from` another container, a bind mount
whose source is not a direct child of `/opt/<app>/` (the Docker socket,
deeper paths and `..` included), is `state/` or the allow file, or is a
symlink on disk, a named volume or network that is external, carries
`driver_opts` or another project's name (the shared `proxy` network
excepted), and `secrets`/`configs` files by the same rule as binds. The
refusal names each finding, such as `app.cap_add`; the production stack stays
as it was. A previous tag that fails the policy is not rolled back to.

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
tag must still name that ID, and `up --pull never` starts what is on disk. A
tag pushed again in the meantime (the CI token writes to the registry) stops
the run with "production untouched". The rollback pulls the previous tag
explicitly and goes the same way.

An exception is a line in `/opt/<app>/compose-policy-allow` with the finding
exactly as the refusal prints it; `#` starts a comment. Only root writes the
file: `deploy-app` stops when it is not a regular file of root or is writable
by group or others. An exception for a deeper bind brings the symlink case
back for that path.

```bash
echo 'socket-proxy.volumes:/var/run/docker.sock  # read-only API for the tool' \
  | sudo tee -a /opt/<app>/compose-policy-allow
sudo chmod 644 /opt/<app>/compose-policy-allow
```
