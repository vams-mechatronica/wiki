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

1. **Node**: the pipeline uses `agent any`. Whichever node runs it needs the Docker CLI, the Compose v2 plugin, `curl` and `gzip`, plus access to the Docker daemon. The shared Jenkins container (`api-services/jenkins`) already has all of these: its built-in node uses the host's `/var/run/docker.sock`.
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
| `APP_URL` | `https://wiki.thenearbyshop.com` | Public URL of the wiki |
| `DOCMOST_PORT` | `3000` | Host port |
| `HEALTHCHECK_URL` | `http://docmost-wiki:3000` | Jenkins sits on `webnet`, so it checks the container directly. Leave empty to use `APP_URL` |
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

## Public access: wiki.thenearbyshop.com

TLS and routing are handled by the shared edge nginx in the
[api-services](https://github.com/vams-mechatronica/api-services) repo
(`deploy/nginx/api-stage.conf` and `deploy/nginx/domains.txt`):

- The `docmost` container joins the external `webnet` Docker network with the alias **`docmost-wiki`**. The edge proxies `wiki.thenearbyshop.com` to `docmost-wiki:3000`, including WebSocket upgrades for live editing. Postgres and Redis stay on the project's private network.
- Port 3000 is published on `127.0.0.1` only, so the wiki is reachable from outside only through the edge.
- To go live:
  1. Point the DNS A record for `wiki.thenearbyshop.com` at the server.
  2. Run the api-services **edge** Jenkins job. It expands the shared certificate, then applies the nginx config.
  3. Deploy this stack with `DEPLOY_TARGET=local`. Jenkins runs on the same host and is on `webnet`.

## Production notes

- Uploads through the edge are capped at 50 MB (`client_max_body_size` in the edge's wiki block).
- Pin `DOCMOST_VERSION` and upgrade deliberately. Check the Docmost release notes before you do.
