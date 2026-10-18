# Docker Compose + Traefik Templates

## Standard Architecture

```
                  ┌─ /opt/traefik (one per server) ─────────────────┐
Internet → 80/443 │ traefik ── socket ── socket-proxy → docker.sock │
                  └──┬──────────────────────────────────────────────┘
                     │ proxy (external, shared by all projects)
          ┌──────────┴──────────┐
     projA: app            projB: app
          │ projA_backend       │ projB_backend   (per project, not shared)
     db, redis             db, redis
```

One Traefik per server, in its own stack at `/opt/traefik/`. A project compose
never contains `traefik` or `socket-proxy`: a second project would collide on
`container_name` and on ports 80/443, and `docker compose down` of the first
project would take every site on the server offline.

Networks:

- `proxy` — external, created once per server. Traefik and the routed service of
  every project join it. Nothing else joins it.
- `backend` — declared inside each project compose, not external. Compose names
  it `<project>_backend`, so every project gets its own. `db`, `redis` and
  workers live here. Do not share a data network between projects: two projects
  with a service named `db` on one network make Docker DNS return both
  addresses, and app A intermittently connects to the database of project B
  (docker/compose#8223).
- `socket` — inside the Traefik stack only, `internal: true`, connects Traefik to
  `socket-proxy`.

Traefik never mounts `/var/run/docker.sock` directly. Mounting the socket into a
container is equivalent to root on the host: the Docker API can start a new
container with `/` bind-mounted, and `:ro` on the socket does not prevent it.
`socket-proxy` exposes a read-only subset of the API over TCP instead.

Traefik router, service and middleware names are global for the whole server.
Two projects with `traefik.http.routers.app` conflict, and Traefik drops both
routers (404 on both domains). Every name in labels carries the prefix
`${COMPOSE_PROJECT_NAME}`.

## Initial Server Setup

Run once per server, before the first project deploy. From the local machine:

```bash
vps-init <IP> <name>   # admin user, sshd hardening, ufw 22, reboot at 04:00 off VPN; adds `Host <name>` to ~/.ssh/config
web-init <name>        # Docker CE, this Traefik stack, network proxy, ufw 80/443, user deployer
```

`web-init` lives in the `bin/` of the skill next to `vps-init`. It is idempotent and stops without changes if a container
outside `/opt/traefik` holds port 80 or 443. It writes the Traefik stack below
verbatim: change the template here and in the script together.
`scripts/check.sh` asserts the result.

Each project compose creates its own `backend` network on `up`; the rest of
the per-project setup is in SKILL.md, step 3.

## Traefik Stack (`/opt/traefik/compose.yml`)

Static configuration is passed only as `command:` flags. Do not add a
`traefik.yml` next to the flags: Traefik reads one source of static
configuration, and a `traefik.yml` does not expand environment variables, so
`email: ${ACME_EMAIL}` in it reaches Let's Encrypt as a literal string. In the
flags below, Compose substitutes `${ACME_EMAIL}` from `/opt/traefik/.env`
before Traefik starts.

```yaml
name: traefik

services:
  traefik:
    image: traefik:v3.6
    restart: unless-stopped
    command:
      - --providers.docker=true
      # Read-only Docker API via socket-proxy, never the raw socket
      - --providers.docker.endpoint=tcp://socket-proxy:2375
      - --providers.docker.exposedByDefault=false
      # Routed containers also sit on their project backend network;
      # Traefik must reach them over proxy
      - --providers.docker.network=proxy
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --entrypoints.web.http.redirections.entryPoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL:?}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.tlschallenge=true
      - --log.level=INFO
    ports:
      - "80:80"
      - "443:443"
    volumes:
      # Named volume: Traefik creates acme.json inside with mode 600 itself
      - certificates:/letsencrypt
    networks:
      - proxy
      - socket
    depends_on:
      - socket-proxy

  socket-proxy:
    image: tecnativa/docker-socket-proxy:v0.5.0
    restart: unless-stopped
    environment:
      # Traefik reads container labels and networks; everything else stays refused
      CONTAINERS: 1
      NETWORKS: 1
      POST: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - socket

volumes:
  certificates:

networks:
  proxy:
    external: true
  socket:
    internal: true
```

## Project Stack

The template is `assets/compose.yml` with `assets/.env.example`. On the server
the project lives in `/opt/<app>/`; the compose file itself is not stored
there, the deploy script reads it from the image.

Rules the template encodes, keep them when adapting:

- No `traefik`, no `socket-proxy`, no `container_name`, no `ports:` in a
  project. Traefik reaches the routed service over `proxy`; anything else stays
  on `backend`. A published port bypasses ufw (`check.sh` fails on it).
- Every Traefik router, service and middleware name starts with
  `${COMPOSE_PROJECT_NAME}`.
- Images come from `<DEVOPS_REGISTRY>/<owner>/${COMPOSE_PROJECT_NAME}:${IMAGE_TAG}`;
  the tag is a commit hash, never `latest`. The server never builds.
- `read_only`, `tmpfs: /tmp`, `no-new-privileges`, non-root `USER` in the
  Dockerfile.
- No `logging:`: services inherit the journald driver of the daemon (web-init),
  so logs survive the container recreation on every deploy. They are kept
  30 days / 2G; read them with `docker logs <name>` or
  `journalctl CONTAINER_NAME=<name>` (web-init puts the admin in
  `systemd-journal`; takes effect on the next login).
- Variables without a working default are `${NAME:?}`.
- Migrations run in the one-shot `migrate` service before `app` starts
  (`migration-patterns.md`).

### Background worker

Same image, other command, `backend` only, no labels:

```yaml
  worker:
    <<: *application
    command: ["arq", "app.worker.settings.WorkerSettings"]
    restart: unless-stopped
    depends_on:
      migrate:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
```

## www Redirect (if needed)

Add these labels to the app service. The middleware name carries the project
prefix too: middlewares are global, like routers. Add `www.<domain>` to
`ALLOWED_HOSTS` in `/opt/<app>/.env`: deploy-app refuses a rule for a host
that is not in `SITE_DOMAIN` or `ALLOWED_HOSTS`.

```yaml
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-www.rule=Host(`www.${SITE_DOMAIN}`)"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-www.entrypoints=websecure"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-www.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-www.service=${COMPOSE_PROJECT_NAME}"
      - "traefik.http.routers.${COMPOSE_PROJECT_NAME}-www.middlewares=${COMPOSE_PROJECT_NAME}-redirect-www"
      - "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-redirect-www.redirectregex.regex=^https://www\\.(.+)"
      - "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-redirect-www.redirectregex.replacement=https://$${1}"
      - "traefik.http.middlewares.${COMPOSE_PROJECT_NAME}-redirect-www.redirectregex.permanent=true"
```

## Non-Docker Exceptions

If a service runs outside Docker, document it in `docs/deployment.md`:
```markdown
## Non-containerized services
- **[service name]**: Runs on host directly because [reason].
  - Managed by: systemd / supervisord
  - Config: /etc/service/config.conf
  - Start: sudo systemctl start service
```
