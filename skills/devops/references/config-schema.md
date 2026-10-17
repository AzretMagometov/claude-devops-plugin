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
| `app` | Compose project name = repository name = `COMPOSE_PROJECT_NAME`. Unique per server, and not `<other>_*` for another project on it, nor a prefix of one (`demo` next to `demo_x`): compose names volumes `<app>_<name>`, so volume `x_data` of `demo` is volume `data` of `demo_x`. `add-project.sh` refuses such a pair. Gives `/opt/<app>`, the key line `deploy-app <app>`, the image `<DEVOPS_REGISTRY>/<DEVOPS_REGISTRY_USER>/<app>` (on GitHub `ghcr.io/<owner>/<app>`). |
| `domain` | Host the server Traefik routes to the project: `SITE_DOMAIN` in `/opt/<app>/.env`. More hosts of the project go to `ALLOWED_HOSTS` there (commas or spaces); deploy-app refuses a Traefik rule or certificate for any other host. |
| `repo` | Repository URL on Forgejo or GitHub. |

Secrets live in two places only:

- the server: `/opt/<app>/.env`, `root:deployer 640`;
- the forge: repository secrets of `<repo>` (`forgejo-actions.md`,
  `github-actions.md`).

Generating and storing secret values is the job of the secrets-keeper skill.
