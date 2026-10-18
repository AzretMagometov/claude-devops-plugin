# .devops-config

A JSON file in the project root. It names where the project goes and nothing
else. It holds no secrets, so it may be committed.

```json
{
  "server": "prod",
  "app": "myapp",
  "domain": "myapp.ru",
  "repo": "https://git.example.com/ops/myapp"
}
```

| Key | Value |
|-----|-------|
| `server` | IP or `~/.ssh/config` alias of the server. The user is always `DEVOPS_ADMIN` from `~/.config/devops/env`. |
| `app` | Compose project name = repository name = `COMPOSE_PROJECT_NAME`. Unique per server, and not `<other>_*` for another project on it, nor a prefix of one (`demo` next to `demo_x`): compose names volumes `<app>_<name>`, so volume `x_data` of `demo` is volume `data` of `demo_x`. `add-project.sh` refuses such a pair. Gives `/opt/<app>`, the key line `deploy-app <app>`, the image `<DEVOPS_REGISTRY>/<owner>/<app>` in lower case (on GitHub `ghcr.io/<owner>/<app>`). The repository name may differ from `app`. |
| `domain` | Host the server Traefik routes to the project: `SITE_DOMAIN` in `/opt/<app>/.env`. More hosts of the project go to `ALLOWED_HOSTS` there (commas or spaces); deploy-app refuses a Traefik rule or certificate for any other host. |
| `repo` | Repository URL on Forgejo or GitHub. A fallback only: the scripts read `git remote get-url origin` first, because repositories move between owners and this value goes stale after a transfer. |

## Owner and repository

Repositories live under several owners (a user, organizations) and move
between them. `devops_repo` in `lib/config.sh` reads the owner and the
repository name in this order:

1. `git remote get-url origin` of the project directory;
2. `repo` in `.devops-config`;
3. `DEVOPS_REGISTRY_USER` from `~/.config/devops/env`, repository name = `app`.

Accepted remote forms, with or without `.git` and a trailing slash:
`https://host[:port]/owner/repo`, `ssh://[user@]host[:port]/owner/repo`,
`[user@]host:owner/repo`. The owner and the name are the last two path
segments.

Host rule: a `github.com` remote is GitHub. Any other remote host (a domain,
the server IP, an `~/.ssh/config` alias, any port) is the one configured
Forgejo, so the API and registry host is `DEVOPS_REGISTRY`.

The image owner is the repository owner in lower case. The registry login is
`DEVOPS_REGISTRY_LOGIN` (default `DEVOPS_REGISTRY_USER`): an organization owns
images but cannot log in, so a repository of an organization needs
`REGISTRY_USER=<login>` in `/opt/<app>/.env` and the repository variable
`REGISTRY_USER`.

Secrets live in two places only:

- the server: `/opt/<app>/.env`, `root:deployer 640`;
- the forge: repository secrets of `<repo>` (`forgejo-actions.md`,
  `github-actions.md`).

Generating and storing secret values is the job of the secrets-keeper skill.
