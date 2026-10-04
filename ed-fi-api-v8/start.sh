#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Starts the Ed-Fi API v8 pilot kit. A thin wrapper around `docker compose up`; the actual
# initialization work happens in the one-shot containers under init/ (compose.init.yml). See
# scripts/lib.sh for the shared helpers this and its siblings (stop.sh, reset.sh, bootstrap.sh) use.

set -euo pipefail

# Git Bash on Windows otherwise rewrites container paths such as /init/... into Windows paths
# (spike-notes Q1). scripts/lib.sh also sets this, so this line matters only if that ever changes.
export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/lib.sh
. "$SCRIPT_DIR/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: ./start.sh [--template minimal|populated] [--help]

Starts the Ed-Fi API v8 pilot kit:
  1. Checks that Docker is running and Compose 2.20 or later is available.
  2. Creates .env from .env.example with freshly generated local secrets, if .env doesn't exist yet
     (an existing .env is never modified; missing variables are only reported).
  3. Generates a local, self-signed TLS certificate under ssl/, if one doesn't exist yet.
  4. Creates .runtime/ and the NGINX log directory, if needed.
  5. Runs `docker compose up -d --build --wait`.

Options:
  --template minimal|populated  Set DATABASE_TEMPLATE in .env before starting. Only takes effect on
                                 a database that has not been initialized yet -- changing it on an
                                 existing database requires ./reset.sh (see ./reset.sh --help).
  --help                        Show this help and exit.

On success, prints the kit's URLs, the template actually in use, and the bootstrap credentials
file path. On failure, names the service(s) that failed, shows their recent logs, prints the exact
`docker compose logs <service>` command, and exits non-zero. Running ./start.sh again against an
already-running stack exits 0 and makes no changes.
EOF
}

template=""
while [ $# -gt 0 ]; do
    case "$1" in
        --template)
            [ $# -ge 2 ] || {
                usage >&2
                kit_die "--template requires a value (minimal or populated)"
            }
            template="$2"
            shift 2
            ;;
        --template=*)
            template="${1#*=}"
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            kit_die "unknown argument: $1"
            ;;
    esac
done

if [ -n "$template" ] && [ "$template" != "minimal" ] && [ "$template" != "populated" ]; then
    usage >&2
    kit_die "--template must be 'minimal' or 'populated', got '$template'"
fi

kit_require_docker
kit_require_compose
kit_ensure_env

if [ -n "$template" ]; then
    previous=$(kit_env_get DATABASE_TEMPLATE "minimal")
    kit_env_set DATABASE_TEMPLATE "$template"
    if [ "$previous" != "$template" ]; then
        kit_log "DATABASE_TEMPLATE set to '$template' in .env."
        kit_log "This only affects a database that has not been initialized yet: if one already"
        kit_log "exists with a different template, init-template will warn and skip instead of"
        kit_log "reloading. Run './reset.sh --start' to switch templates on existing data."
    fi
fi

kit_ensure_certs
kit_ensure_dirs

kit_log "Starting the stack (docker compose up -d --build --wait)."
kit_log "This can take a few minutes on first run: image pulls, the tools image build, schema"
kit_log "provisioning, and the template load all happen before this command returns."

if ! kit_compose up -d --build --wait; then
    kit_log ""
    kit_log "Startup did not complete. Checking service status..."
    failures=$(kit_compose_failures || true)
    if [ -n "$failures" ]; then
        while IFS="$(printf '\t')" read -r svc reason; do
            [ -n "$svc" ] || continue
            kit_log "FAILED: $svc ($reason)"
            kit_show_failure_logs "$svc"
        done <<<"$failures"
    else
        kit_log "No individual service was reported as exited or unhealthy. Inspect further with:"
        kit_log "  (cd \"$KIT_DIR\" && docker compose ps -a)"
        kit_log "  (cd \"$KIT_DIR\" && docker compose logs)"
    fi
    exit 1
fi

kit_log ""
kit_log "Ed-Fi API v8 pilot kit is up."
kit_log ""
kit_print_urls
kit_log ""
kit_log "Template in use: $(kit_current_template)"
kit_log ""
kit_log "Bootstrap (admin) credentials: $KIT_DIR/.runtime/bootstrap-credentials.json"
kit_log "This is an administrative credential for local testing only -- it is not representative of"
kit_log "a production integration client."
kit_log ""
kit_log "Next steps:"
kit_log "  - Create a scoped credential: ./new-credential.sh --shape sis --name <your-name>"
kit_log "  - Run the smoke test:         ./smoke-test.sh"
