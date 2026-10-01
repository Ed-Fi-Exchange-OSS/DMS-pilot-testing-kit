#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Task 12: reruns bootstrapping (the bootstrap credential and the baseline education organization
# hierarchy, init/bootstrap.sh) against an already-running stack, without a destructive reset
# (FR-BOOT-10). Useful to repair an environment where bootstrap-credentials.json was lost, or a
# baseline record was deleted by hand.

set -euo pipefail

export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/lib.sh
. "$SCRIPT_DIR/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage: ./bootstrap.sh [--help]

Reruns bootstrapping (the bootstrap credential and the baseline education organization hierarchy)
against a running stack: docker compose run --rm init-bootstrap.

Requires the stack to already be started (./start.sh); `docker compose run` would otherwise start
every dependency on its own, so this checks first and fails with a clear message instead.
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

kit_stack_running dms ||
    kit_die "the stack is not running. Run ./start.sh first, then ./bootstrap.sh."

kit_compose run --rm init-bootstrap

kit_log ""
kit_log "Bootstrap complete."
kit_log "Credentials: $KIT_DIR/.runtime/bootstrap-credentials.json"
