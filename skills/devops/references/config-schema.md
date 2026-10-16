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
| `app` | Compose project name = repository name = `COMPOSE_PROJECT_NAME`. Unique per server. Gives `/opt/<app>`, the key line `deploy-app <app>`, the image `<DEVOPS_REGISTRY>/<DEVOPS_REGISTRY_USER>/<app>` (on GitHub `ghcr.io/<owner>/<app>`). |
| `domain` | Host the server Traefik routes to the project. |
| `repo` | Repository URL on Forgejo or GitHub. |

Secrets live in two places only:

- the server: `/opt/<app>/.env`, `root:deployer 640`;
- the forge: repository secrets of `<repo>` (`forgejo-actions.md`,
  `github-actions.md`).

Generating and storing secret values is the job of the secrets-keeper skill.
