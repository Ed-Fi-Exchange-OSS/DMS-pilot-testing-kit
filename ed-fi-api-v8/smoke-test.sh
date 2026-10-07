#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Host wrapper for Task 14 (Task 12's start/stop/reset/bootstrap and Task 13's new-credential are its
# siblings, but this script depends on none of them and is self-contained). Runs init/smoke-test.sh
# inside the tools container, non-interactively exercising the same path as http/smoke.http through
# NGINX:
#   docker compose run --rm --no-deps --user 0:0 tools sh /init/smoke-test.sh
# --no-deps so a stopped stack fails with "run start first" instead of being started. The tools
# service mounts http/ read-only for the edorgs.http consistency check (FR-EDORG-14). This script's
# exit code is the container's. --debug is passed in as SMOKE_TEST_DEBUG=1 (docker compose run -e).

set -euo pipefail

# Git Bash on Windows otherwise rewrites container paths such as /init/... into Windows paths
# (spike-notes Q1).
export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat <<'EOF'
Usage: ./smoke-test.sh [--check-edorgs-only] [--debug] [--help]

Runs the kit's non-interactive smoke test against the running stack, through NGINX, so routing and
TLS are exercised too (not just DMS directly). Exercises the same requests http/smoke.http documents:
a token, Discovery, a descriptor read, a write and read-back, offset/limit and cursor paging, a
change-query extract, an ETag update plus a stale-ETag 412, a deliberately invalid request, and (on
the populated template only) an assessment-style reference write. Prints one PASS/FAIL/SKIP line per
step and a summary, and exits non-zero if any step failed.

Options:
  --check-edorgs-only  Only run the http/edorgs.http vs bootstrap/baseline-edorgs.json consistency
                        check (FR-EDORG-14) and exit -- skips every DMS/NGINX request.
  --debug               Print each client key/secret pair the test reads or creates, to help
                        diagnose authorization failures. WARNING: this prints live secrets; do not
                        share the output.
  --help                Show this help and exit.

Requires a stack already started with ./start.sh (or start.ps1): Docker running, .env present, the
tools image built, and .runtime/bootstrap-credentials.json written.
EOF
}

CHECK_EDORGS_ONLY=0
DEBUG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check-edorgs-only)
            CHECK_EDORGS_ONLY=1
            shift
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1 (see --help)" >&2
            exit 1
            ;;
    esac
done

if ! docker info >/dev/null 2>&1; then
    echo "Docker does not appear to be running. Start Docker Desktop and try again." >&2
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo ".env not found in $SCRIPT_DIR. Copy .env.example to .env first, then run start." >&2
    exit 1
fi

if ! docker image inspect edfi-pilot-tools:local >/dev/null 2>&1; then
    echo "The tools image (edfi-pilot-tools:local) has not been built yet: run start first." >&2
    exit 1
fi

if [ "$CHECK_EDORGS_ONLY" -eq 1 ]; then
    exec docker compose run --rm --no-deps --user 0:0 tools \
        sh /init/check-edorgs-http.sh
fi

if [ ! -f "$SCRIPT_DIR/.runtime/bootstrap-credentials.json" ]; then
    echo ".runtime/bootstrap-credentials.json not found in $SCRIPT_DIR. Run start first (or" \
        "./bootstrap.sh if the stack is already up)." >&2
    exit 1
fi

exec docker compose run --rm --no-deps --user 0:0 -e "SMOKE_TEST_DEBUG=$DEBUG" tools \
    sh /init/smoke-test.sh
