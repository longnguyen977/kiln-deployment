# Kiln ATS — Deployment

Single source of truth for building and deploying the Kiln ATS platform
to a single EC2 host. Manages the **backend**, **frontend**, and
**extensions** subrepos as git submodules and ships a `deploy.sh`
tool that drives `docker compose` with per-environment state persisted
in `deploy/<env>.env`.

---

## Table of contents

- [Architecture](#architecture)
- [Repo layout](#repo-layout)
- [Prerequisites](#prerequisites)
- [First-time setup](#first-time-setup)
- [Daily workflow](#daily-workflow)
- [Rollback](#rollback)
- [Operations](#operations)
- [Migrations](#migrations)
- [How it works](#how-it-works)
- [Updating a submodule](#updating-a-submodule)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                 ┌────────────────────────────────────────────────┐
                 │                EC2 (t3.xlarge)                 │
                 │                                                │
   Internet ───► │  nginx (TLS, optional) ──┐                     │
                 │                           │                    │
                 │           ┌──────────────┤────────────────┐    │
                 │           ▼              ▼                │    │
                 │    ┌─────────────┐  ┌─────────────┐       │    │
                 │    │  Next.js 16 │  │  Go backend │       │    │
                 │    │   :3000     │  │   :8080     │       │    │
                 │    │ (frontend)  │  │ (backend)   │       │    │
                 │    └─────────────┘  └──────┬──────┘       │    │
                 │                            │              │    │
                 │                            ▼              │    │
                 │                    ┌───────────────┐      │    │
                 │                    │  Postgres     │◄─────┘    │
                 │                    │  (host-level, │           │
                 │                    │   external to │           │
                 │                    │   docker)     │           │
                 │                    └───────────────┘           │
                 └────────────────────────────────────────────────┘
                                           │
                                           ▼
                                 ┌───────────────────┐
                                 │  AWS S3 (files)   │
                                 │  kiln-files-sg-*  │
                                 └───────────────────┘
```

- **Backend** (`kiln-backend-service`): Go + Fiber, port `8080`, connects
  to host-level Postgres via `host.docker.internal`, uploads CVs to S3.
- **Frontend** (`kiln-frontend-service`): Next.js 16, port `3000`,
  SSR calls backend via `${BACKEND_URL}`; browser-side uses
  `NEXT_PUBLIC_*` vars baked in at build time.
- **Postgres**: runs on the host (not in docker). Backups via AWS Backup
  + nightly `pg_dump` to S3.
- **Storage**: S3 Standard, pre-signed URLs for browser uploads/downloads.
- **Nginx**: terminates TLS and reverse-proxies `:8080` / `:3000`
  (configured outside this repo).

---

## Repo layout

```
kiln-deployment/                  ← this repo
├── deploy.sh                     ← deploy tool (build / deploy / rollback)
├── migration.sh                  ← goose migration runner (schema changes)
├── docker-compose.yml            ← bridge-network compose (--external, default)
├── docker-compose.host.yml       ← host-network compose  (--internal)
├── docker/
│   ├── backend.dockerfile        ← multi-stage Go build
│   ├── frontend.dockerfile       ← multi-stage Next.js build
│   └── migration.dockerfile      ← goose + psql, ~15 MB
├── deploy/
│   ├── dev.env                   ← state: VERSION_*, BACKEND_URL, paths (committed)
│   └── prod.env
├── env/
│   ├── .env.dev.example          ← copy → .env.dev, fill secrets (gitignored)
│   └── .env.prod.example
├── sql/
│   └── database.sql              ← monolithic schema for emergency restore
├── backend/                      ← submodule: kiln-backend
├── frontend/                     ← submodule: kiln-frontend
└── extensions/                   ← submodule: kiln-extentions
```

### Submodules

| Path         | Repo                                   | Purpose                      |
|--------------|----------------------------------------|------------------------------|
| `backend/`   | `longnguyen977/kiln-backend`           | Go + Fiber API               |
| `frontend/`  | `longnguyen977/kiln-frontend`          | Next.js 16 / React 19 app    |
| `extensions/`| `longnguyen977/kiln-extentions`        | Chrome extension (Kiln Capture) |

---

## Prerequisites

### On the deploy host (EC2)

- **OS**: Amazon Linux 2023 / Ubuntu 22.04+
- **Docker Engine** 24+ with the Compose plugin (`docker compose version` must work)
- **PostgreSQL** 15+ installed and listening on `127.0.0.1:5432` (docker
  containers reach it via `host.docker.internal` — wired up by
  `extra_hosts` in `docker-compose.yml`)
- **git** with SSH access to `github.com:longnguyen977/*`
- **4 GB swap file** (Next.js build can spike RAM — the swap prevents OOM kills)
- **nginx** or similar reverse proxy (optional; outside this repo)

### AWS

- **S3 bucket** for file storage (`kiln-files-sg-prod`, region `ap-southeast-1`)
- **IAM user or instance role** with `s3:PutObject` / `s3:GetObject` /
  `s3:DeleteObject` on that bucket

### Third-party

- **Google OAuth 2.0** credentials (`credentials/google_oauth.json` in backend)
- **Google Gemini API key** for AI features
- **PostHog** project token (optional — leave empty to disable analytics)

---

## First-time setup

### 1. Clone with submodules

```bash
git clone --recurse-submodules git@github.com:longnguyen977/kiln-deployment.git
cd kiln-deployment
```

If you cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Fill in secrets

```bash
# Backend runtime env (DATABASE_URL, JWT, AWS keys, Google OAuth, etc.)
cp env/.env.prod.example env/.env.prod
chmod 600 env/.env.prod
$EDITOR env/.env.prod
```

### Deploy Google OAuth credentials

The JSON gets **bind-mounted** into the backend container — never copied
into the image. So it stays on disk only, rotations don't require a
rebuild, and the image is safe to share.

From your laptop:

```bash
# Use scp — NOT ftp. FTP is plaintext; scp uses your SSH key.
scp -i ~/.ssh/kiln.pem google_oauth.json \
    ubuntu@<ec2-ip>:/home/ubuntu/kiln-deployment/backend/credentials/google_oauth.json

# On the EC2, lock down permissions
ssh ubuntu@<ec2-ip> \
  "chmod 600 ~/kiln-deployment/backend/credentials/google_oauth.json && \
   ls -l ~/kiln-deployment/backend/credentials/"
```

docker-compose mounts `./backend/credentials` as read-only at
`/app/credentials` inside the container. The backend reads
`GOOGLE_CRED_FILE=credentials/google_oauth.json` (see `env/.env.prod`)
— the relative path resolves to the mounted file. Rotating the key
is: `scp new-key → old-backend container restart` (no rebuild).

### Future: migrate secrets off disk

For tighter ops, replace the file-on-disk with one of:

| Option | Cost | Effort | Good for |
|---|---|---|---|
| **AWS Parameter Store (SecureString)** | free tier ≥ enough | small Go change | single prod env |
| **AWS Secrets Manager** | ~$0.40 per secret/mo | small Go change | rotations, audit |
| **sops / age** encrypted file in repo | free | medium | GitOps-style |

All three let you remove `backend/credentials/` from the EC2 entirely
— the backend fetches at startup. Worth doing once you have more
than one deploy surface.

### 3. Edit server-facing values

```bash
$EDITOR deploy/prod.env                # set SERVER_IP + BACKEND_URL
$EDITOR frontend/.env.local            # set NEXT_PUBLIC_* vars, rebuild after
```

### 4. Prepare Postgres (external to docker)

```bash
# On the host
sudo -u postgres psql
  CREATE USER kiln WITH PASSWORD '<strong-password>';
  CREATE DATABASE kiln OWNER kiln;
  \q

# Confirm DATABASE_URL in env/.env.prod matches.
# Make sure postgres listens on 0.0.0.0:5432 or 127.0.0.1 + pg_hba allows
# the docker bridge subnet (e.g. 172.17.0.0/16).
```

### 5. Run migrations (via `migration.sh`)

```bash
./migration.sh up -e prod
```

Builds a small goose-only container (first run only) and applies every
pending migration against the DB in `env/.env.prod`. See
[Migrations](#migrations) below for the full command reference.

### 6. First deploy

```bash
./deploy.sh up -e prod -v 1.0.0
```

This builds both images as `kiln-backend:1.0.0-prod` and
`kiln-frontend:1.0.0-prod`, updates `deploy/prod.env`, and starts the
containers.

Verify:

```bash
./deploy.sh status -e prod
curl -sS http://localhost:8080/          # backend
curl -sS http://localhost:3000/          # frontend
```

---

## Daily workflow

All deploys go through `./deploy.sh`. The version (`-v`) becomes the
image tag and is persisted to `deploy/<env>.env`, so rebooted hosts come
back up on the right version.

### Deploy both services

```bash
./deploy.sh up -e prod -v 1.0.1
```

### Deploy only backend

```bash
cd backend && git pull origin main && cd ..
./deploy.sh backend -e prod -v 1.0.1
```

### Deploy only frontend

```bash
cd frontend && git pull origin main && cd ..
# frontend/.env.local is baked in at build time — re-check it first
./deploy.sh frontend -e prod -v 1.0.1
```

### Check status

```bash
./deploy.sh status -e prod
```

### Tail logs

```bash
./deploy.sh logs -e prod backend     # backend only
./deploy.sh logs -e prod frontend    # frontend only
./deploy.sh logs -e prod             # both
```

### Stop everything

```bash
./deploy.sh down -e prod
```

---

## Rollback

Rollback swaps image tags **without rebuilding** — seconds, not minutes.
The target version's images must still exist locally (Docker only prunes
them if you explicitly run `docker image prune`).

```bash
./deploy.sh rollback -e prod -v 1.0.0
```

`deploy.sh` verifies both `kiln-backend:1.0.0-prod` and
`kiln-frontend:1.0.0-prod` exist before swapping and will refuse to run
if either is missing.

---

## Operations

### Version state

The file `deploy/<env>.env` is the source of truth for "what's running".
It looks like:

```
VERSION_BACKEND=1.0.1-prod
VERSION_FRONTEND=1.0.1-prod
BACKEND_ENV_FILE=./env/.env.prod
SERVER_IP=1.2.3.4
BACKEND_URL=http://1.2.3.4:8080
```

`deploy.sh` updates the `VERSION_*` lines on every deploy. Edit
`SERVER_IP` and `BACKEND_URL` by hand when the server moves.

### Logs & log rotation

Docker logs are capped at **10 MB × 5 files per container** (see
`logging:` in `docker-compose.yml`). Nothing to rotate manually.

### Container internals

```bash
docker exec -it kiln-backend-service sh
docker exec -it kiln-frontend-service sh
```

### DB migrations after a schema change

Migrations are not auto-run by `deploy.sh`. See [Migrations](#migrations)
for the full workflow — the one-liner is:

```bash
./migration.sh up -e prod
```

---

## Migrations

Schema changes are handled by `./migration.sh`, a thin wrapper around
[goose](https://github.com/pressly/goose) that runs inside a 15 MB
ephemeral container (`docker/migration.dockerfile`). Deliberately
separate from `deploy.sh` so routine app deploys can't accidentally
touch schema.

### How it's wired

- The container holds only the `goose` binary + `psql` client (no Go
  toolchain, no Next.js, no backend code).
- `backend/db/migrations/` is **bind-mounted** at runtime — no image
  rebuild needed when you add migrations.
- `DATABASE_URL` / `GOOSE_DBSTRING` come from `env/.env.<env>`, the
  same file the backend container uses. **Single source of truth for
  DB connection**, no drift between app and migration configs.

### Network mode (`--internal` vs `--external`)

Two docker networking modes, pick the one that matches your DB string:

| Flag | Docker network | When to use | DB string host |
|---|---|---|---|
| `--external` *(default)* | bridge + host.docker.internal wired | Postgres is on host **and** you're using `host.docker.internal` in the DB string, OR Postgres is elsewhere (RDS, remote VPS) | `host.docker.internal` or real DNS |
| `--internal` | `--network host` | Postgres is on the **same host** and you want `localhost:5432` to work (Linux only) | `localhost` or `127.0.0.1` |

If you see errors like `dial tcp 127.0.0.1:5432: connect: connection refused`,
your DB string uses `localhost` but the default bridge mode is active.
Either switch to `--internal` or change the DB string to
`host.docker.internal`.

### Common commands

```bash
./migration.sh up       -e prod           # apply all pending
./migration.sh status   -e prod           # show applied + pending
./migration.sh version  -e prod           # current schema version
./migration.sh down     -e prod           # roll back one
./migration.sh redo     -e prod           # roll back + re-apply last
./migration.sh up-to    20260501000000 -e prod    # partial upgrade
./migration.sh down-to  20260414000010 -e prod    # partial rollback
./migration.sh validate -e prod           # lint migrations, don't run
```

### Creating a new migration

```bash
./migration.sh create add_email_index -e dev
# writes backend/db/migrations/<timestamp>_add_email_index.sql
```

Edit the generated SQL, commit to the **backend** submodule, push,
then `./migration.sh up -e prod` on the deploy host.

### Interactive shell (goose + psql)

For ad-hoc DB inspection:

```bash
./migration.sh shell -e prod
# inside the container:
#   goose status
#   psql "$DATABASE_URL"
```

### Reset (destructive)

`./migration.sh reset -e prod` rolls back every migration. It will
**prompt for confirmation** — type the env name to proceed. Do not
script this.

### Upgrading goose

Edit `ARG GOOSE_VERSION=...` at the top of
`docker/migration.dockerfile`, then:

```bash
./migration.sh build
```

---

## How it works

### No more sed-generated compose

Older versions of this repo ran `sed` over `base-<env>.yml` to build a
fresh `docker-compose.yml` on every deploy. That had a real bug: a
per-service rebuild would overwrite the other service's version in the
generated file, leaving a stale compose file that referenced wrong image
tags on next reboot.

Now there is a **single real `docker-compose.yml`** that uses docker
compose's native `${VAR:?}` substitution. All state lives in
`deploy/<env>.env`, consumed via `docker compose --env-file …`. Per-service
rebuilds only update that service's `VERSION_*` field and the compose
file always reflects reality.

### Why env files live in two places

- `env/.env.<env>` — backend *runtime* secrets (DATABASE_URL, JWT,
  AWS keys, OAuth, etc.). Loaded into the backend container via
  `env_file:`. **Gitignored.**
- `deploy/<env>.env` — deployment *state* (VERSION_*, paths, server IPs).
  Loaded via `--env-file` for compose variable substitution. **Committed.**

### Why Postgres is outside docker

Running Postgres in docker on a single host adds risk (volume management,
accidental pruning) without meaningful benefit. Host-level Postgres is
easier to back up, tune, and move to RDS later. The docker services
reach it via `host.docker.internal` + `extra_hosts: host-gateway`.

### Network mode: `--internal` vs `--external`

Both `deploy.sh` and `migration.sh` accept `--internal` / `--external`
flags that control how docker containers reach host-level Postgres.
They resolve to **two different compose files** (because
`network_mode: host` can't be cleanly toggled via override):

| Mode | Compose file | Docker network | Use when | DB string host |
|---|---|---|---|---|
| `--external` *(default)* | `docker-compose.yml` | bridge + `host.docker.internal` wired | Postgres is reached via `host.docker.internal`, OR Postgres is elsewhere (RDS, remote) | `host.docker.internal` / real DNS |
| `--internal` | `docker-compose.host.yml` | `network_mode: host` | Postgres is on the **same host** and DB string uses `localhost` | `localhost` / `127.0.0.1` |

`deploy.sh` persists the choice in `deploy/<env>.env` as
`NETWORK_MODE=…` — pass the flag once, every subsequent command (and
reboots) honor it. `migration.sh` doesn't persist; pass the flag each
time (or match whatever `deploy.sh` is using).

**Symptom that tells you the mode is wrong:** you see
`dial tcp 127.0.0.1:5432: connect: connection refused` in the backend
logs. Either flip to `--internal` or change the DB string in
`env/.env.<env>` to use `host.docker.internal`.

Host network mode is **Linux-only** and the right choice for the EC2
production host. On macOS Docker Desktop it silently falls back to
bridge mode, so local dev should stick with `--external`.

### Why frontend env is baked in at build time

Next.js inlines `NEXT_PUBLIC_*` env vars into the client bundle during
`next build`. Changing them requires a rebuild. `frontend/.env.local`
is copied into the build context by `docker/frontend.dockerfile`.

---

## Updating a submodule

Submodules are pinned to a specific commit. Pulling changes in a
submodule does not update the parent repo — you have to commit the
new pin explicitly.

### Bump a submodule to latest `main`

```bash
cd backend
git pull origin main
cd ..

# Root repo now sees backend as "modified" (points to a new commit).
git add backend
git commit -m "chore: bump backend to <short-sha>"
git push
```

Repeat for `frontend/` or `extensions/`.

### Clone updates on another host

```bash
git pull
git submodule update --init --recursive
```

---

## Troubleshooting

### "env file ./env/.env.prod not found"

Copy `env/.env.prod.example → env/.env.prod` and fill in the values.

### Backend can't reach Postgres

- Confirm Postgres is listening: `sudo ss -tlnp | grep 5432`
- Confirm `pg_hba.conf` allows the docker bridge subnet
  (usually `172.17.0.0/16`)
- Inside the container: `docker exec -it kiln-backend-service sh -c 'nc -zv host.docker.internal 5432'`

### Frontend shows old NEXT_PUBLIC_* values

Those are baked in at build time. Edit `frontend/.env.local`, then run
`./deploy.sh frontend -e prod -v <new-version>` — not `restart`.

### Rollback fails: "image … not found locally"

The target version's image was pruned. Either rebuild it
(`./deploy.sh up -e prod -v <version>`) or push images to a registry so
rollback can pull them.

### `next build` OOMs during frontend build

Add a swap file on the EC2:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Submodule shows "modified" but I didn't change anything

You probably ran `git pull` inside the submodule. Commit the new pin in
the parent repo (see [Updating a submodule](#updating-a-submodule)) or
reset the submodule back to the pinned commit:

```bash
git submodule update --init --recursive
```

---

## Command reference

### `deploy.sh` — build + ship app code

```
./deploy.sh up        -e <env> -v <version> [--internal|--external]
./deploy.sh backend   -e <env> -v <version>
./deploy.sh frontend  -e <env> -v <version>
./deploy.sh rollback  -e <env> -v <version>
./deploy.sh down      -e <env>
./deploy.sh status    -e <env>                 (shows NETWORK_MODE too)
./deploy.sh logs      -e <env> [service]
./deploy.sh help

--internal / --external flip the compose file used for this env
(docker-compose.yml vs docker-compose.host.yml) and are STICKY —
persisted to deploy/<env>.env as NETWORK_MODE so reboots use the
same mode without you having to pass the flag again.
```

### `migration.sh` — schema changes

```
./migration.sh up                 -e <env> [--internal|--external]
./migration.sh up-by-one          -e <env> [--internal|--external]
./migration.sh up-to   <version>  -e <env> [--internal|--external]
./migration.sh down               -e <env> [--internal|--external]
./migration.sh down-to <version>  -e <env> [--internal|--external]
./migration.sh redo               -e <env> [--internal|--external]
./migration.sh reset              -e <env> [--internal|--external]     (destructive)
./migration.sh status             -e <env> [--internal|--external]
./migration.sh version            -e <env> [--internal|--external]
./migration.sh validate           -e <env> [--internal|--external]
./migration.sh create  <name>     -e <env>
./migration.sh shell              -e <env> [--internal|--external]
./migration.sh build
./migration.sh help

--internal  : --network host       (use with DB string "localhost:5432")
--external  : bridge + host-gateway (default; use "host.docker.internal")
```
