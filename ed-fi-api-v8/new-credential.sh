#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Host wrapper for Task 13 (Task 12's start/stop/reset/bootstrap are its siblings, but this script
# depends on none of them and is self-contained). Validates arguments locally for fast feedback, then
# hands them, unmodified, to init/new-credential.sh inside the tools container:
#   docker compose run --rm --no-deps --user 0:0 tools sh /init/new-credential.sh ...
# --no-deps so a stopped stack fails with "run start first" instead of being started; --user 0:0 so
# the container can write .runtime/credentials/ (see init/bootstrap.sh for the ownership handling
# init/new-credential.sh reuses). This script's own exit code is whatever that container exits with.

set -euo pipefail

# Git Bash on Windows otherwise rewrites container paths such as /init/... into Windows paths
# (spike-notes Q1).
export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat <<'EOF'
Usage: ./new-credential.sh --shape sis|assessment|warehouse --name <name>
                            [--claim-set <name>] [--edorg-ids 1,2,3]

  --shape       Required. sis -> SISVendor, assessment -> AssessmentVendor, warehouse -> DataWarehouse.
  --name        Required. Unique. Letters, digits, '.', '_', '-' only; 1-64 characters.
  --claim-set   Optional override of the claim set implied by --shape. Must already exist in CMS.
  --edorg-ids   Optional comma-separated education organization ids. Defaults depend on --shape and
                the loaded template: the bootstrapped SEA on minimal, the sample LEA on populated, or
                none for warehouse credentials.
EOF
}

SHAPE=""
NAME=""
CLAIM_SET=""
EDORG_IDS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --shape)
            [ $# -ge 2 ] || { echo "--shape requires a value" >&2; exit 1; }
            SHAPE="$2"
            shift 2
            ;;
        --shape=*) SHAPE="${1#*=}"; shift ;;
        --name)
            [ $# -ge 2 ] || { echo "--name requires a value" >&2; exit 1; }
            NAME="$2"
            shift 2
            ;;
        --name=*) NAME="${1#*=}"; shift ;;
        --claim-set)
            [ $# -ge 2 ] || { echo "--claim-set requires a value" >&2; exit 1; }
            CLAIM_SET="$2"
            shift 2
            ;;
        --claim-set=*) CLAIM_SET="${1#*=}"; shift ;;
        --edorg-ids)
            [ $# -ge 2 ] || { echo "--edorg-ids requires a value" >&2; exit 1; }
            EDORG_IDS="$2"
            shift 2
            ;;
        --edorg-ids=*) EDORG_IDS="${1#*=}"; shift ;;
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

case "$SHAPE" in
    sis | assessment | warehouse) ;;
    "")
        echo "--shape is required: sis, assessment, or warehouse" >&2
        exit 1
        ;;
    *)
        echo "--shape must be sis, assessment, or warehouse (got '$SHAPE')" >&2
        exit 1
        ;;
esac

if [ -z "$NAME" ]; then
    echo "--name is required" >&2
    exit 1
fi
case "$NAME" in
    *[!A-Za-z0-9._-]*)
        echo "--name may contain only letters, digits, '.', '_', and '-' (got '$NAME')" >&2
        exit 1
        ;;
esac
NAME_LEN=${#NAME}
if [ "$NAME_LEN" -lt 1 ] || [ "$NAME_LEN" -gt 64 ]; then
    echo "--name must be 1-64 characters (got $NAME_LEN)" >&2
    exit 1
fi

if [ -n "$EDORG_IDS" ]; then
    case "$EDORG_IDS" in
        *[!0-9,]*)
            echo "--edorg-ids must be a comma-separated list of numbers (got '$EDORG_IDS')" >&2
            exit 1
            ;;
    esac
fi

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

args=(--shape "$SHAPE" --name "$NAME")
if [ -n "$CLAIM_SET" ]; then
    args+=(--claim-set "$CLAIM_SET")
fi
if [ -n "$EDORG_IDS" ]; then
    args+=(--edorg-ids "$EDORG_IDS")
fi

exec docker compose run --rm --no-deps --user 0:0 tools sh /init/new-credential.sh "${args[@]}"
