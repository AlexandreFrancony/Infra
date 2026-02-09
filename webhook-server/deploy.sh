#!/bin/bash
#
# Central Deployment Script
# Pulls latest changes and rebuilds Docker containers for any project
#
# Environment variables (set by webhook server):
#   PROJECT_NAME  - Name of the project (e.g., "Bartending", "MTG-Collection")
#   PROJECT_PATH  - Full path to project directory
#   COMPOSE_FILE  - Full path to docker-compose.yml (optional, overrides COMPOSE_DIR)
#   COMPOSE_DIR   - Subdirectory containing docker-compose.yml (optional)
#   REPOS         - Comma-separated list of repo names to pull
#   BRANCH        - Branch to deploy (e.g., "main", "prod")

set -e

# Configuration
HOSTING_DIR="${HOSTING_DIR:-/home/bloster/Hosting}"
LOG_FILE="/var/log/infra/deploy.log"
LOCK_DIR="/tmp/infra_deploy.lock"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Logging
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] [${PROJECT_NAME}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "${YELLOW}$@${NC}"; }
log_error() { log "ERROR" "${RED}$@${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$@${NC}"; }

# Acquire lock
acquire_lock() {
    local timeout=${1:-300}
    local start_time=$(date +%s)

    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo "$$" > "$LOCK_DIR/pid"
            echo "$PROJECT_NAME" > "$LOCK_DIR/project"
            date -Iseconds > "$LOCK_DIR/started"
            log_info "Acquired deployment lock"
            return 0
        fi

        # Check if lock is stale
        if [ -f "$LOCK_DIR/pid" ]; then
            local lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
            if ! kill -0 "$lock_pid" 2>/dev/null; then
                log_warn "Removing stale lock (PID $lock_pid not running)"
                rm -rf "$LOCK_DIR"
                continue
            fi
        fi

        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $timeout ]; then
            log_error "Could not acquire lock after ${timeout}s"
            return 1
        fi

        log_info "Waiting for lock... (${elapsed}s elapsed)"
        sleep 5
    done
}

# Release lock
release_lock() {
    rm -rf "$LOCK_DIR"
    log_info "Released deployment lock"
}

# Cleanup on exit
cleanup() {
    release_lock
}
trap cleanup EXIT

# Pull changes for a repository
pull_repo() {
    local repo_path=$1
    local branch=${2:-main}

    if [ ! -d "$repo_path/.git" ]; then
        log_warn "Not a git repo: $repo_path"
        return 0
    fi

    log_info "Pulling $repo_path (branch: $branch)..."

    (
        cd "$repo_path"
        git fetch origin
        git reset --hard "origin/$branch"
        # Note: Don't use 'git clean -fd' as it removes untracked files like credentials
    )

    local short_commit=$(cd "$repo_path" && git rev-parse --short HEAD)
    log_info "$(basename $repo_path) is now at commit $short_commit"
}

# Deploy with docker compose
deploy_compose() {
    local compose_path=$1
    local compose_file=$2

    # If a specific compose file is provided, use it
    # NOTE: docker compose CLI runs inside the container, so ALL paths must be container paths
    # The compose file itself contains host paths for build contexts (read by Docker daemon via socket)
    if [ -n "$compose_file" ] && [ -f "$compose_file" ]; then
        log_info "Using compose file: $compose_file"

        # Check for corresponding .env file
        local env_file="${compose_file%.yml}.env"
        local env_args=""
        if [ -f "$env_file" ]; then
            log_info "Using env file: $env_file"
            env_args="--env-file $env_file"
        fi

        log_info "Building and deploying containers..."
        docker compose -f "$compose_file" $env_args build
        docker compose -f "$compose_file" $env_args up -d
        log_info "Verifying deployment..."
        docker compose -f "$compose_file" $env_args ps
        return 0
    fi

    # Otherwise look for docker-compose.yml in the path
    local found_compose=""
    if [ -f "$compose_path/docker-compose.yml" ]; then
        found_compose="$compose_path/docker-compose.yml"
    elif [ -f "$compose_path/docker-compose.yaml" ]; then
        found_compose="$compose_path/docker-compose.yaml"
    else
        log_error "No docker-compose.yml found in $compose_path"
        return 1
    fi

    log_info "Using compose file: $found_compose"
    log_info "Building and deploying containers..."
    docker compose -f "$found_compose" build
    docker compose -f "$found_compose" up -d

    log_info "Verifying deployment..."
    docker compose -f "$found_compose" ps
}

# Main
main() {
    log_info "=========================================="
    log_info "Starting deployment: $PROJECT_NAME"
    log_info "=========================================="

    if [ -z "$PROJECT_PATH" ]; then
        log_error "PROJECT_PATH not set"
        exit 1
    fi

    acquire_lock

    # Pull all repos
    if [ -n "$REPOS" ]; then
        IFS=',' read -ra REPO_LIST <<< "$REPOS"
        for repo in "${REPO_LIST[@]}"; do
            repo_path="$PROJECT_PATH/$repo"
            if [ -d "$repo_path" ]; then
                pull_repo "$repo_path" "$BRANCH"
            else
                # Maybe the project is the repo itself
                if [ -d "$PROJECT_PATH/.git" ]; then
                    pull_repo "$PROJECT_PATH" "$BRANCH"
                    break
                fi
            fi
        done
    else
        # Single repo project
        pull_repo "$PROJECT_PATH" "$BRANCH"
    fi

    # Determine compose location
    local compose_dir="$PROJECT_PATH"
    if [ -n "$COMPOSE_DIR" ]; then
        compose_dir="$PROJECT_PATH/$COMPOSE_DIR"
    fi

    # Deploy (pass COMPOSE_FILE if set)
    deploy_compose "$compose_dir" "$COMPOSE_FILE"

    # Cleanup old images
    log_info "Cleaning up old Docker images..."
    docker image prune -f --filter "until=24h" 2>/dev/null || true

    log_success "=========================================="
    log_success "Deployment completed: $PROJECT_NAME"
    log_success "=========================================="
}

main "$@"
