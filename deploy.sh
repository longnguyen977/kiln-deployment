#!/usr/bin/env bash
# Kiln ATS deploy tool.
# Single source of truth for build + deploy. All state lives in
# deploy/<env>.env (persisted across runs) — no generated compose files.

set -euo pipefail

readonly BACKEND_SERVICE="kiln-backend-service"
readonly FRONTEND_SERVICE="kiln-frontend-service"
readonly BACKEND_IMAGE="kiln-backend"
readonly FRONTEND_IMAGE="kiln-frontend"

readonly COMPOSE_EXTERNAL="docker-compose.yml"       # bridge network + host.docker.internal
readonly COMPOSE_INTERNAL="docker-compose.host.yml"  # host network mode

usage() {
    cat <<EOF
Usage: ./deploy.sh <command> [options]

Commands:
  up        -e <env> -v <version>    Build + deploy both services
  backend   -e <env> -v <version>    Build + deploy backend only
  frontend  -e <env> -v <version>    Build + deploy frontend only
  rollback  -e <env> -v <version>    Re-tag to existing images (no build)
  down      -e <env>                 Stop & remove both services
  status    -e <env>                 Show running versions + ps
  logs      -e <env> [service]       Tail logs (backend|frontend|all)
  help                               Show this message

Options:
  -e | --env <dev|prod>    Target environment (required for most commands)
  -v | --version <x.y.z>   Semver without suffix (e.g. 1.0.0); env is appended
  --internal               Use HOST network mode (Postgres on same host;
                           DB strings use 'localhost'). Linux only.
                           Persisted to deploy/<env>.env.
  --external               Use bridge network + host.docker.internal (default).
                           Persisted to deploy/<env>.env.
  -h | --help              Show this message

Examples:
  ./deploy.sh up       -e prod -v 1.0.0 --internal
  ./deploy.sh backend  -e prod -v 1.0.1
  ./deploy.sh rollback -e prod -v 1.0.0
  ./deploy.sh logs     -e prod backend

Notes:
  - First-time migrations are run via ./migration.sh — see README.
  - Network mode is sticky: set it once with --internal/--external and
    all subsequent commands (including reboots) use the same file.
  - Edit deploy/<env>.env for SERVER_IP / API_URL; secrets live in env/.env.<env>.
EOF
}

die() { echo "error: $*" >&2; exit 1; }

check_docker() {
    command -v docker >/dev/null || die "docker not installed"
    docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
}

check_env() {
    local env=$1
    [[ "$env" == "dev" || "$env" == "prod" ]] || die "env must be 'dev' or 'prod' (got '$env')"
    [[ -f "deploy/${env}.env" ]]  || die "deploy/${env}.env not found"
    [[ -f "env/.env.${env}" ]]    || die "env/.env.${env} not found (copy env/.env.${env}.example)"
}

# Rewrite (or append) a single KEY=VALUE line in deploy/<env>.env in-place.
set_state() {
    local env=$1 key=$2 val=$3
    local file="deploy/${env}.env"
    if grep -qE "^${key}=" "$file"; then
        if sed --version >/dev/null 2>&1; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$file"
        else
            sed -i '' "s|^${key}=.*|${key}=${val}|" "$file"
        fi
    else
        printf '\n%s=%s\n' "$key" "$val" >> "$file"
    fi
}

get_state() {
    local env=$1 key=$2
    grep -E "^${key}=" "deploy/${env}.env" 2>/dev/null | cut -d= -f2- || true
}

# Return the compose file matching the env's persisted NETWORK_MODE.
compose_file_for() {
    local env=$1
    local mode
    mode=$(get_state "$env" NETWORK_MODE)
    mode=${mode:-external}                        # backward-compat default
    if [[ "$mode" == "internal" ]]; then
        echo "$COMPOSE_INTERNAL"
    else
        echo "$COMPOSE_EXTERNAL"
    fi
}

compose() {
    local env=$1; shift
    local file
    file=$(compose_file_for "$env")
    docker compose --env-file "deploy/${env}.env" -f "$file" "$@"
}

build_backend() {
    local env=$1 version=$2
    local tag="${BACKEND_IMAGE}:${version}-${env}"
    echo "==> building ${tag}"
    docker build -f docker/backend.dockerfile . -t "$tag"
    set_state "$env" VERSION_BACKEND "${version}-${env}"
}

build_frontend() {
    local env=$1 version=$2
    local tag="${FRONTEND_IMAGE}:${version}-${env}"
    echo "==> building ${tag}"
    docker build -f docker/frontend.dockerfile . -t "$tag"
    set_state "$env" VERSION_FRONTEND "${version}-${env}"
}

require_image() {
    local tag=$1
    docker image inspect "$tag" >/dev/null 2>&1 \
        || die "image $tag not found locally — build it first (no remote registry)"
}

cmd_up() {
    local env=$1 version=$2
    build_backend  "$env" "$version"
    build_frontend "$env" "$version"
    echo "==> starting services"
    compose "$env" up -d "$BACKEND_SERVICE" "$FRONTEND_SERVICE"
    cmd_status "$env"
}

cmd_backend() {
    local env=$1 version=$2
    build_backend "$env" "$version"
    echo "==> restarting $BACKEND_SERVICE"
    compose "$env" up -d --force-recreate "$BACKEND_SERVICE"
    cmd_status "$env"
}

cmd_frontend() {
    local env=$1 version=$2
    build_frontend "$env" "$version"
    echo "==> restarting $FRONTEND_SERVICE"
    compose "$env" up -d --force-recreate "$FRONTEND_SERVICE"
    cmd_status "$env"
}

cmd_rollback() {
    local env=$1 version=$2
    local btag="${BACKEND_IMAGE}:${version}-${env}"
    local ftag="${FRONTEND_IMAGE}:${version}-${env}"
    require_image "$btag"
    require_image "$ftag"
    set_state "$env" VERSION_BACKEND  "${version}-${env}"
    set_state "$env" VERSION_FRONTEND "${version}-${env}"
    echo "==> rolling back to ${version}-${env}"
    compose "$env" up -d --force-recreate "$BACKEND_SERVICE" "$FRONTEND_SERVICE"
    cmd_status "$env"
}

cmd_down() {
    local env=$1
    compose "$env" down
}

cmd_status() {
    local env=$1
    local mode
    mode=$(get_state "$env" NETWORK_MODE); mode=${mode:-external}
    echo "==> ${env} state (deploy/${env}.env)"
    echo "    VERSION_BACKEND  = $(get_state "$env" VERSION_BACKEND)"
    echo "    VERSION_FRONTEND = $(get_state "$env" VERSION_FRONTEND)"
    echo "    NETWORK_MODE     = ${mode}  (compose file: $(compose_file_for "$env"))"
    echo "    BACKEND_URL         = $(get_state "$env" BACKEND_URL)"
    echo "    FRONTEND_URL        = $(get_state "$env" FRONTEND_URL)"
    echo "    GOOGLE_REDIRECT_URL = $(get_state "$env" GOOGLE_REDIRECT_URL)"
    echo "    GMAIL_REDIRECT_URL  = $(get_state "$env" GMAIL_REDIRECT_URL)"
    echo "    COOKIE_DOMAIN       = $(get_state "$env" COOKIE_DOMAIN)"
    echo "    EXTENSION_S3_KEY    = $(get_state "$env" EXTENSION_S3_KEY)"
    echo "==> running containers"
    compose "$env" ps
}

cmd_logs() {
    local env=$1 target=${2:-all}
    case "$target" in
        backend)  compose "$env" logs -f --tail=200 "$BACKEND_SERVICE" ;;
        frontend) compose "$env" logs -f --tail=200 "$FRONTEND_SERVICE" ;;
        all|"")   compose "$env" logs -f --tail=200 ;;
        *)        die "unknown log target: $target (use backend|frontend|all)" ;;
    esac
}

# ─── arg parsing ───────────────────────────────────────────────────────
[[ $# -ge 1 ]] || { usage; exit 1; }

cmd=$1; shift
env=""
version=""
network_mode=""
extra=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)     env=${2:?}; shift 2 ;;
        -v|--version) version=${2:?}; shift 2 ;;
        --internal)   network_mode="internal"; shift ;;
        --external)   network_mode="external"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            extra+=("$1"); shift ;;
    esac
done

case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
esac

check_docker
[[ -n "$env" ]] || die "missing -e <dev|prod>"
check_env "$env"

# Persist network mode if the flag was passed. Sticky: applies to all
# subsequent commands until overridden.
if [[ -n "$network_mode" ]]; then
    set_state "$env" NETWORK_MODE "$network_mode"
    echo "==> NETWORK_MODE set to '$network_mode' (persisted to deploy/${env}.env)"
fi

needs_version() {
    [[ -n "$version" ]] || die "missing -v <version> for '$cmd'"
}

case "$cmd" in
    up)        needs_version; cmd_up       "$env" "$version" ;;
    backend)   needs_version; cmd_backend  "$env" "$version" ;;
    frontend)  needs_version; cmd_frontend "$env" "$version" ;;
    rollback)  needs_version; cmd_rollback "$env" "$version" ;;
    down)      cmd_down   "$env" ;;
    status)    cmd_status "$env" ;;
    logs)      cmd_logs   "$env" "${extra[0]:-all}" ;;
    *)         die "unknown command: $cmd (try ./deploy.sh help)" ;;
esac
