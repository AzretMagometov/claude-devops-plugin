# GitHub Actions: CI/CD with images on GHCR

Template: `assets/.github/workflows/ci.yml`, used when `DEVOPS_FORGE=github`.
The jobs are those of the Forgejo template (`forgejo-actions.md`): `test`,
`build` (only a green `main`), `deploy` (`ssh deployer@<host> "deploy <sha>"`),
manual run with `image_tag` = rollback. Only the `test` job is stack-specific.

Differences from the Forgejo template:

- sources come from `actions/checkout`, pinned to an exact release;
- the image is `ghcr.io/<owner>/<repo>` in lower case: GHCR refuses upper
  case, and `github.repository` keeps it, so a step writes `IMAGE` to
  `$GITHUB_ENV`;
- `build` pushes with the `GITHUB_TOKEN` of the run (`permissions:
  packages: write` on that job only); there is no `REGISTRY_TOKEN` secret.

## Secrets and tokens

| Where | Name | Value |
|-------|------|-------|
| repository secret | `DEPLOY_HOST` | server IP |
| repository secret | `DEPLOY_SSH_KEY` | private half of the deployer key |
| repository secret | `DEPLOY_HOST_KEY` | `<IP> ssh-ed25519 AAAA...` |
| server `/opt/<app>/.env` | `IMAGE` | `ghcr.io/<owner>/<repo>`, lower case |
| server `/opt/<app>/.env` | `REGISTRY_USER` | GitHub login of the token owner |
| server `/opt/<app>/.env` | `REGISTRY_TOKEN` | personal access token (classic), scope `read:packages` only |

`add-project.sh` sets the three secrets with `gh secret set --repo
<owner>/<repo>` of the git remote (`GITHUB_REPO` overrides it) when `gh` is
installed and `gh auth status` succeeds. Otherwise it prints the three
`gh secret set` commands in the `Waiting for you:` block, and the private
key waits in a temporary directory until the user deletes it.

`scripts/forge-check.sh` with `DEVOPS_FORGE=github` reads the state through
`gh api`: secret and variable names of the repository, the organization
entries the repository may read (`actions/organization-secrets`,
`actions/organization-variables`), queued runs, self-hosted runners only when
`runs-on` names `self-hosted` (otherwise `RUNNER=hosted`), and the package
list of the owner. GET of one package answers 404 without `read:packages`,
the list answers 403, so the script reads the list: without the scope
`IMAGE=unknown`.

The server token is a classic PAT: GHCR does not accept fine-grained tokens.
`read:packages` cannot push, so a stolen server `.env` cannot replace an image.

## Package visibility

The first push creates the package `ghcr.io/<owner>/<repo>`, private and
linked to the repository. It stays private: the server pulls with the
`read:packages` token. The package settings (Profile → Packages → <repo> →
Package settings) must keep the repository under "Manage Actions access"
with the Write role; without it the next `build` gets `denied` on push.
