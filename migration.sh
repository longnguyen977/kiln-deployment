#!/usr/bin/env bash
# Kiln ATS — goose migration runner.
# Scope: first-time deploy + schema updates. Not part of deploy.sh so
# routine app deploys can't accidentally touch schema.
#
# Runs goose inside a small ephemeral container (docker/migration.dockerfile)
# that mounts backend/db/migrations from the host. DB creds come from
# env/.env.<env> — same file the backend container uses, so the connection
# string can't drift between app and migrations.

set -euo pipefail

readonly IMAGE="kiln-migration:latest"
readonly MIGRATIONS_DIR="backend/db/migrations"

usage() {
    cat <<EOF
Usage: ./migration.sh <command> -e <env> [--internal|--external] [args]

Commands:
  up                       Apply all pending migrations
  up-by-one                Apply next single pending migration
  up-to <version>          Apply up to a specific version
  down                     Roll back one migration
  down-to <version>        Roll back to a specific version
  redo                     Roll back + re-apply last migration
  reset                    Roll back ALL migrations  (DESTRUCTIVE)
  status                   Show applied / pending migrations
  version                  Print current schema version
  validate                 Validate migrations without applying
  create <name>            Generate a new SQL migration file
  shell                    Interactive shell with goose + psql available
  build                    Build/rebuild the migration image
  help                     Show this message

Options:
  -e | --env <dev|prod>    Target environment (required for most commands)
  --internal               Use HOST network  (Postgres on same host as docker).
                           DB string can use 'localhost:5432'. Linux only.
  --external               Use BRIDGE network + host.docker.internal wiring
                           (default). DB string must use 'host.docker.internal'
                           for host-level Postgres, or a real DNS name for RDS.

Examples:
  # Postgres on the same EC2 host, DB string uses localhost:
  ./migration.sh up      -e prod --internal

  # Postgres on the same EC2 host, DB string uses host.docker.internal (default):
  ./migration.sh up      -e prod

  # Postgres on RDS or another server:
  ./migration.sh up      -e prod --external

  ./migration.sh create  add_email_index -e dev
  ./migration.sh up-to   20260501120000  -e prod
  ./migration.sh shell   -e prod --internal

Notes:
  - Image is auto-built on first use.
  - 'reset' requires typing the env name to confirm.
  - 'create' writes to ${MIGRATIONS_DIR}/ on the host.
  - --internal uses '--network host' which is Linux-only; on macOS/Windows
    it silently falls back to bridge mode. Use --external on dev macs.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

check_docker() {
    command -v docker >/dev/null || die "docker not installed"
    docker info >/dev/null 2>&1 || die "docker daemon not running"
}

check_env() {
    local env=$1
    [[ "$env" == "dev" || "$env" == "prod" ]] || die "env must be 'dev' or 'prod' (got '$env')"
    [[ -f "env/.env.${env}" ]] || die "env/.env.${env} not found (copy env/.env.${env}.example)"
    [[ -d "$MIGRATIONS_DIR" ]] || die "$MIGRATIONS_DIR not found — did you clone with --recurse-submodules?"
}

build_image() {
    echo "==> building $IMAGE"
    docker build -f docker/migration.dockerfile -t "$IMAGE" .
}

ensure_image() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || build_image
}

# Build the docker-run network flags based on $network_mode.
# Populates a global array $NET_FLAGS.
build_net_flags() {
    if [[ "$network_mode" == "internal" ]]; then
        # Host networking: container shares host's network stack;
        # 'localhost' in the container reaches the host's Postgres directly.
        NET_FLAGS=(--network host)
    else
        # Default bridge network; wire 'host.docker.internal' so DB strings
        # targeting host-level Postgres keep working, and leave real DNS
        # (RDS endpoints etc.) to resolve normally.
        NET_FLAGS=(--add-host "host.docker.internal:host-gateway")
    fi
}

run_goose() {
    local env=$1; shift
    build_net_flags
    docker run --rm \
        --env-file "env/.env.${env}" \
        -e GOOSE_MIGRATION_DIR=/app/migrations \
        -v "$(pwd)/${MIGRATIONS_DIR}:/app/migrations" \
        "${NET_FLAGS[@]}" \
        "$IMAGE" "$@"
}

run_shell() {
    local env=$1
    build_net_flags
    echo "==> entering migration shell (env=${env}, network=${network_mode}) — 'goose' and 'psql' available"
    docker run --rm -it \
        --env-file "env/.env.${env}" \
        -e GOOSE_MIGRATION_DIR=/app/migrations \
        -v "$(pwd)/${MIGRATIONS_DIR}:/app/migrations" \
        "${NET_FLAGS[@]}" \
        --entrypoint sh \
        "$IMAGE"
}

confirm_destructive() {
    local env=$1 action=$2
    echo
    echo "!!  $action on env=${env}  !!"
    echo "This is DESTRUCTIVE. Type the env name ('${env}') to proceed:"
    read -r answer
    [[ "$answer" == "$env" ]] || die "aborted"
}

# ─── arg parsing ───────────────────────────────────────────────────────
[[ $# -ge 1 ]] || { usage; exit 1; }

cmd=$1; shift
env=""
network_mode="external"
args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)   env=${2:?}; shift 2 ;;
        --internal) network_mode="internal"; shift ;;
        --external) network_mode="external"; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          args+=("$1"); shift ;;
    esac
done

case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    build)          check_docker; build_image; exit 0 ;;
esac

check_docker
[[ -n "$env" ]] || die "missing -e <dev|prod>"
check_env "$env"
ensure_image

case "$cmd" in
    up|up-by-one|down|redo|status|version|validate)
        run_goose "$env" "$cmd"
        ;;
    up-to|down-to)
        [[ ${#args[@]} -ge 1 ]] || die "'$cmd' needs a version argument"
        run_goose "$env" "$cmd" "${args[0]}"
        ;;
    reset)
        confirm_destructive "$env" "RESET (roll back ALL migrations)"
        run_goose "$env" reset
        ;;
    create)
        [[ ${#args[@]} -ge 1 ]] || die "'create' needs a name argument"
        run_goose "$env" create "${args[0]}" sql
        ;;
    shell)
        run_shell "$env"
        ;;
    *)
        die "unknown command: '$cmd' (try ./migration.sh help)"
        ;;
esac
