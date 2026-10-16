# Database Migrations

## Where migrations run

In the one-shot `migrate` service of the project compose (`assets/compose.yml`):
same image as `app`, another command, `restart: "no"`. `app` starts only after
`migrate` exits with 0 (`condition: service_completed_successfully`). The
deploy script runs `up --wait`, so every deploy applies pending migrations, and
a failed migration leaves `app` on the previous image.

Nobody runs `docker compose exec app <migrate>` on the server: the only path to
production is CI → deploy script.

## Rule: backward-compatible with the previous image

When the new stack is not healthy, the deploy script rolls back to the previous
**image**. The schema stays where the migration left it. So the previous image
must work on the new schema:

- add a column as nullable or with a default; never drop or rename it in the
  same release that stops using it;
- rename = add new column → release that writes both → backfill → release that
  reads the new one → drop the old one in a later release;
- a new `NOT NULL` constraint goes in after the code that fills the column has
  been in production;
- no `downgrade` in the deploy path: it is a development tool.

## Rollback past a migration

The previous image comes back with its own compose file, so its `migrate`
runs again, now on a database that the new release has migrated further. The
command must treat a database ahead of the image as "nothing to do": the rule
above makes the schema usable by the old code.

Alembic does not: `alembic upgrade head` on a revision it does not know exits
with `Can't locate revision identified by '<rev>'`, `app` never starts, and
the rollback ends with "the rollback to <tag> did not come up: needs a human".
The template command (`assets/compose.yml`) wraps it:

1. `alembic heads` checks the revision graph of the image without the
   database. A broken graph fails here and is never mistaken for a database
   ahead of the image.
2. `alembic current` fails with `locate revision identified by` only when the
   database revision is missing from the image: log
   `migrate: the database revision is newer than this image …` and exit 0.
   Any other failure exits 1.
3. `exec alembic upgrade head`: every failure of a real migration still fails
   the rollout.

The wrapper needs `sh` in the image: every python base image has it, a
distroless image does not.

Why in the command and not a flag from deploy-app for its rollback branch:
the manual rollback (Actions → ci → Run workflow with the previous tag) is an
ordinary rollout, which a rollback-only flag does not reach; and a flag works
only through a compose file that reads it, the same one-release lag as the
command.

The fix works from the second release after adoption: deploy-app rolls back to
the compose file inside the previous image, so the previous image must carry
the new command already. Tests: `scripts/migrate_test.sh` runs the template
command against SQLite.

Django, Rails and Laravel skip applied migrations that the code does not know,
so their commands need no wrapper. For Prisma, check `migrate deploy` on a
database ahead of the image before relying on the rollback.

## Dump before a migration

deploy-app dumps the running `postgres` service before every rollout into
`/opt/<app>/state/pre-deploy.sql.gz`: one file, overwritten by the next
rollout, mode 600. It covers every database of the cluster except templates
(for example, an error tracker next to the app database): for each one a
`\connect "<db>"` line, then `pg_dump --clean --if-exists` of that database.
The file restores over the live cluster from any database. A failed dump of
any database stops the rollout. Not `pg_dumpall`: its `--clean` drops the
databases and the role in use, which fails on a live cluster.

Restore it with every service that writes to the databases stopped, so none
writes in between (`docker compose` is not usable here: it reads `.env`,
closed to the admin):

```bash
ssh <admin>@<host> "docker stop <app>-app-1 \
  && sudo gunzip -c /opt/<app>/state/pre-deploy.sql.gz \
  | docker exec -i <app>-postgres-1 sh -c 'psql -q -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d postgres'"
```

Then roll back the image: Actions → ci → Run workflow with the previous tag.
The dump is not a backup: one copy on the same disk. Backups with retention
are out of scope here.

## `migrate.command` per stack

| Stack | `command` |
|-------|-----------|
| Alembic (FastAPI, SQLAlchemy) | the `sh -c` wrapper of `assets/compose.yml` around `alembic upgrade head` |
| Django | `["python", "manage.py", "migrate", "--noinput"]` |
| Prisma | `["npx", "prisma", "migrate", "deploy"]` |
| Laravel | `["php", "artisan", "migrate", "--force"]` |
| Rails | `["bundle", "exec", "rails", "db:migrate"]` |

The command must be idempotent: on a schema already at head it does nothing.
That is true for all the tools above. It must also exit 0 on a database ahead
of the image (see "Rollback past a migration").

## Checking for missing migrations in CI

Add to the `test` job where the stack supports it, so a model change without
a migration fails before it reaches `main`:

| Stack | Command |
|-------|---------|
| Alembic | `alembic check` |
| Django | `python manage.py makemigrations --check --dry-run` |
