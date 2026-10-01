#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Task 12: stops the stack without touching any persisted data (FR-LIFE-5). Containers are stopped,
# not removed, and volumes are untouched; ./start.sh starts the same containers again.

set -euo pipefail

export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/lib.sh
. "$SCRIPT_DIR/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: ./stop.sh [--help]

Stops the Ed-Fi API v8 pilot kit (docker compose stop). All persisted data -- the database, the
ApiSchema volume, the Data Standard cache, and pgAdmin's data -- is kept. Start it again with
./start.sh.
EOF
}

for arg in "$@"; do
    case "$arg" in
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

kit_compose stop

kit_log ""
kit_log "Stack stopped. Persisted data was kept."
kit_log "Start it again with: ./start.sh"
