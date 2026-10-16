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
