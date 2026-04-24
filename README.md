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
  SSR calls backend via `${API_URL}`; browser-side uses
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
├── docker-compose.yml            ← real compose, uses ${VAR} substitution
├── docker/
│   ├── backend.dockerfile        ← multi-stage Go build
│   └── frontend.dockerfile       ← multi-stage Next.js build
├── deploy/
│   ├── dev.env                   ← state: VERSION_*, API_URL, paths (committed)
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

Google OAuth JSON goes in the backend submodule:

```bash
mkdir -p backend/credentials
$EDITOR backend/credentials/google_oauth.json     # paste your OAuth client JSON
chmod 600 backend/credentials/google_oauth.json
```

### 3. Edit server-facing values

```bash
$EDITOR deploy/prod.env                # set SERVER_IP + API_URL
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

### 5. Run migrations (manual, one-time)

```bash
cd backend
goose -dir db/migrations postgres "$GOOSE_DBSTRING" up
# or load the monolithic schema:
# psql "$DATABASE_URL" < ../sql/database.sql
cd ..
```

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
API_URL=http://1.2.3.4:8080
```

`deploy.sh` updates the `VERSION_*` lines on every deploy. Edit
`SERVER_IP` and `API_URL` by hand when the server moves.

### Logs & log rotation

Docker logs are capped at **10 MB × 5 files per container** (see
`logging:` in `docker-compose.yml`). Nothing to rotate manually.

### Container internals

```bash
docker exec -it kiln-backend-service sh
docker exec -it kiln-frontend-service sh
```

### DB migrations after a schema change

Migrations are not auto-run. After bumping versions, run from the host:

```bash
cd backend
goose -dir db/migrations postgres "$GOOSE_DBSTRING" up
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

## Deploy command reference

```
./deploy.sh up        -e <env> -v <version>    Build + deploy both services
./deploy.sh backend   -e <env> -v <version>    Build + deploy backend only
./deploy.sh frontend  -e <env> -v <version>    Build + deploy frontend only
./deploy.sh rollback  -e <env> -v <version>    Re-tag to existing images (no build)
./deploy.sh down      -e <env>                 Stop & remove both services
./deploy.sh status    -e <env>                 Show running versions + ps
./deploy.sh logs      -e <env> [service]       Tail logs (backend|frontend|all)
./deploy.sh help                               Show help
```
