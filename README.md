# Docmost Wiki – Jenkins Deployment

Deploys [Docmost](https://github.com/docmost/docmost), an open-source collaborative wiki and documentation tool (an alternative to Confluence and Notion), with **Docker Compose**, driven by a **Jenkins** pipeline.

```
Jenkins agent ──(docker compose, optionally over SSH)──► Docker host
                                                         ├── docmost  (docmost/docmost, :3000)
                                                         ├── db       (postgres:16-alpine)
                                                         └── redis    (redis:7.2-alpine)
```

## Repository layout

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Docmost + PostgreSQL + Redis stack with named volumes and health checks |
| `.env.example` | Every setting the stack reads (Jenkins generates the real `.env`) |
| `Jenkinsfile` | Parameterised pipeline: deploy / backup / restart / stop / status |
| `scripts/healthcheck.sh` | Polls Docmost until it responds |
| `scripts/backup.sh` | Dumps PostgreSQL and archives the file-storage volume, with retention |
| `scripts/restore.sh` | Restores a backup made by `backup.sh` |

## Jenkins setup

1. **Agent**: a node labelled `docker` with the Docker CLI, the Compose v2 plugin, `curl` and `gzip`. The `jenkins` user needs Docker access (it must be in the `docker` group).
2. **Plugins**: Pipeline, Git, Credentials Binding, and SSH Agent (only needed for remote deploys).
3. **Credentials** (*Manage Jenkins → Credentials*):

   | ID | Type | Value |
   |----|------|-------|
   | `docmost-app-secret` | Secret text | `openssl rand -hex 32` |
   | `docmost-db-password` | Secret text | a strong PostgreSQL password |
   | `docmost-ssh` | SSH username with private key | only for `DEPLOY_TARGET=remote` |
   | `docmost-smtp` | Username with password | only when `ENABLE_SMTP` is checked |

   > Keep `docmost-db-password` the same after the first deploy. PostgreSQL only reads it when the database volume is first created.

4. **Job**: create a *Pipeline* job using *Pipeline script from SCM*, pointing at this repository with script path `Jenkinsfile`. Run it once so Jenkins picks up the parameters.

### Remote target

With `DEPLOY_TARGET=remote`, the pipeline sets `DOCKER_HOST=ssh://REMOTE_HOST`, so Compose runs against that host's Docker engine. Nothing is copied to the server. Prerequisites:

- `REMOTE_HOST` (for example `deploy@wiki.example.com`) has Docker installed, and that user is in the `docker` group.
- The host key is in the Jenkins agent's `~/.ssh/known_hosts`. To add it, run `ssh-keyscan wiki.example.com >> ~/.ssh/known_hosts` as the Jenkins user.

## Pipeline parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ACTION` | `deploy` | `deploy`, `backup`, `restart`, `stop`, `status` |
| `DOCMOST_VERSION` | `latest` | Image tag. **Pin a release in production.** |
| `DEPLOY_TARGET` | `local` | `local` or `remote` |
| `REMOTE_HOST` | `deploy@wiki.example.com` | SSH target for remote deploys |
| `APP_URL` | `http://localhost:3000` | Public URL of the wiki |
| `DOCMOST_PORT` | `3000` | Host port |
| `HEALTHCHECK_URL` | *(APP_URL)* | Use this if the agent can't reach the public URL |
| `SKIP_BACKUP` | `false` | Skip the pre-deploy backup |
| `ENABLE_SMTP`, `SMTP_HOST`, `SMTP_PORT`, `MAIL_FROM_ADDRESS` | off | Email for invites and password resets |

### What a `deploy` run does

1. Writes `.env` from the parameters and credentials (mode `600`). The file is always deleted when the build ends.
2. Validates the Compose config and checks that it can reach the Docker engine.
3. Pulls the images.
4. Backs up the database and file storage to `$JENKINS_HOME/backups/docmost`, keeping the 7 most recent. This is skipped on the first deploy.
5. Runs `docker compose up -d`.
6. Health-checks `/api/health`. On failure it prints the container logs and **rolls back** to the previously running image tag, then still marks the build as failed.

> Rolling back the image doesn't undo database migrations. If a new version migrated the schema, restore the pre-deploy backup as well (see below).

## Backups and restore

Backups are written on the Jenkins agent: `docmost-db-<stamp>.sql.gz` and `docmost-storage-<stamp>.tar.gz`. To restore, run this on a machine with the repo and a `.env` file. Set `DOCKER_HOST=ssh://...` first if the stack is remote.

```bash
./scripts/restore.sh backups/docmost-db-20261107-120000.sql.gz backups/docmost-storage-20261107-120000.tar.gz
```

## Manual deploy (without Jenkins)

```bash
cp .env.example .env
```

```bash
docker compose up -d
```

```bash
./scripts/healthcheck.sh http://localhost:3000
```

Then open the `APP_URL` and create the first workspace and admin account.

## Production notes

- Put Docmost behind a TLS-terminating reverse proxy (Nginx, Caddy or Traefik). Set `APP_URL` to the `https://` URL and proxy WebSocket upgrades, which Docmost uses for real-time editing.
- When the proxy runs on the same host, add `DOCMOST_BIND=127.0.0.1` to `.env` so port 3000 isn't exposed publicly.
- Pin `DOCMOST_VERSION` and upgrade deliberately. Check the Docmost release notes before you do.
