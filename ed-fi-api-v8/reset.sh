#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Task 12: the kit's explicit, clearly labelled destructive reset (FR-LIFE-6). Removes every
# persisted volume and the runtime credential files, then optionally starts the kit again fresh --
# the supported way to switch DATABASE_TEMPLATE (FR-TMPL-5) or recover from a corrupted environment
# (NFR-REL-5). Keeps .env and the TLS certificate: only data, not configuration, is destroyed.

set -euo pipefail

export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/lib.sh
. "$SCRIPT_DIR/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: ./reset.sh [--force] [--start] [--help]

DESTRUCTIVE. Removes every persisted volume (the database, the ApiSchema volume, the Data Standard
download cache, and pgAdmin's data) and every file under .runtime/ except .runtime/.gitkeep -- the
bootstrap credentials and any provisioned integration credentials become invalid. .env and the TLS
certificate (ssl/server.crt, ssl/server.key) are kept.

Runs: docker compose down -v --remove-orphans

Options:
  --force   Skip the interactive confirmation (for scripts and CI).
  --start   After resetting, run ./start.sh.
  --help    Show this help and exit.

Without --force, this prompts for confirmation and shows exactly what will be removed. Answering
anything other than "yes" -- or running without --force with no terminal attached to ask --
changes nothing and exits non-zero.
EOF
}

force=false
start_after=false
for arg in "$@"; do
    case "$arg" in
        --force | -Force) force=true ;;
        --start) start_after=true ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            kit_die "unknown argument: $arg"
            ;;
    esac
done

kit_require_docker
kit_require_compose

if [ "$force" != true ]; then
    if [ ! -t 0 ]; then
        kit_die "no terminal attached to confirm. Re-run with --force to reset non-interactively."
    fi
    project=$(kit_env_get KIT_PROJECT_NAME "edfi-pilot")
    cat <<EOF
This permanently deletes, for project '$project':
  - the PostgreSQL database volume: all DMS and CMS data, including anything bootstrapped or
    written since the last reset
  - the ApiSchema volume
  - the Data Standard download cache
  - pgAdmin's data volume
  - every file under $KIT_DIR/.runtime/ except .gitkeep -- the bootstrap credentials and any
    provisioned integration credentials in .runtime/credentials/ become invalid

.env and the TLS certificate (ssl/server.crt, ssl/server.key) are kept.

Runs: docker compose down -v --remove-orphans
EOF
    printf 'Type "yes" to continue: '
    read -r confirm
    if [ "$confirm" != "yes" ]; then
        kit_log "Not confirmed. Nothing was changed."
        exit 1
    fi
fi

kit_compose down -v --remove-orphans

if [ -d "$KIT_DIR/.runtime" ]; then
    find "$KIT_DIR/.runtime" -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} +
fi

kit_log ""
kit_log "Reset complete. .env and the TLS certificate were kept."

if [ "$start_after" = true ]; then
    kit_log ""
    kit_log "Starting the stack again (--start)..."
    exec "$SCRIPT_DIR/start.sh"
fi
