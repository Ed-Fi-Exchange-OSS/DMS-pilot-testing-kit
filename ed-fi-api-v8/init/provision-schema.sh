#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-schema (Task 4): provisions the DS 5.2 schema (tables, indexes, and the dms."EffectiveSchema"
# marker row) into PostgreSQL from the staged ApiSchema files, using EdFi.Api.SchemaTools (tools
# image; see tools/README.md for the exact CLI). Runs after db and config are both healthy -- the
# spike provisioned after CMS had already deployed its own schema, and that order is kept here to
# avoid concurrent DDL against the same database (spike-notes Q5) -- and after init-api-schema has
# staged the volume this mounts read-only.
#
# Idempotent: skips when dms."EffectiveSchema" already holds the hash `api-schema-tools hash`
# computes fresh from the staged schema; dies, naming both hashes, when it holds a different one,
# since that state needs a reset (`docker compose down -v`) rather than a re-run (spike-notes Q5).

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_HASH=compute-hash
STEP_CHECK=check-existing
STEP_PROVISION=provision
STEP_VERIFY=verify

require_env "$STEP_ENV" POSTGRES_PASSWORD POSTGRES_DB_NAME

# DB_HOST/DB_PORT and API_SCHEMA_PATH default to the compose values but are overridable, so this
# script can be run against a local PostgreSQL and a local staged schema without a container.
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
API_SCHEMA_PATH="${API_SCHEMA_PATH:-/app/ApiSchema}"
SCHEMA_FILE="$API_SCHEMA_PATH/Packages/EdFi.DataStandard52.ApiSchema/ApiSchema.json"

export PGHOST="$DB_HOST"
export PGPORT="$DB_PORT"
export PGUSER=postgres
export PGDATABASE="$POSTGRES_DB_NAME"
export PGPASSWORD="$POSTGRES_PASSWORD"

[ -f "$SCHEMA_FILE" ] || die "$STEP_ENV" "staged ApiSchema.json not found at $SCHEMA_FILE"

# ------------------------------------------------------------------------------------------------
# Step a: the expected effective hash, computed fresh from the staged schema on every run.
# `api-schema-tools hash` writes its progress to stdout alongside the "Effective schema hash: ..."
# line (and Serilog lines to stderr; tools/README.md), so the line is picked out by prefix rather
# than assuming the digest is the only thing on stdout.
# ------------------------------------------------------------------------------------------------

HASH_OUTPUT=$(api-schema-tools hash "$SCHEMA_FILE") \
    || die "$STEP_HASH" "api-schema-tools hash failed on $SCHEMA_FILE"
EXPECTED_HASH=""
while IFS= read -r _hash_line; do
    case "$_hash_line" in
        "Effective schema hash: "*)
            EXPECTED_HASH=${_hash_line#"Effective schema hash: "}
            ;;
    esac
done <<EOF
$HASH_OUTPUT
EOF
[ -n "$EXPECTED_HASH" ] || die "$STEP_HASH" "api-schema-tools hash produced no 'Effective schema hash:' line"
log "$STEP_HASH" "expected effective schema hash: $EXPECTED_HASH"

# ------------------------------------------------------------------------------------------------
# Step b: already provisioned? Table existence and row existence stay two separate queries, as in
# init-identity.sh: a query combining to_regclass(...) with a SELECT FROM the same absent table
# fails to *plan*, not just to not-match (spike-notes Q2).
# ------------------------------------------------------------------------------------------------

TABLE_EXISTS=$(kit_psql -f - <<'SQL'
SELECT (to_regclass('dms."EffectiveSchema"') IS NOT NULL);
SQL
)

if [ "$TABLE_EXISTS" = "t" ]; then
    STORED_HASH=$(kit_psql -f - <<'SQL'
SELECT "EffectiveSchemaHash" FROM dms."EffectiveSchema" LIMIT 1;
SQL
)
    if [ "$STORED_HASH" = "$EXPECTED_HASH" ]; then
        log "$STEP_CHECK" "dms.\"EffectiveSchema\" already holds the expected hash, skipping"
        exit 0
    fi
    die "$STEP_CHECK" \
        "dms.\"EffectiveSchema\" holds hash $STORED_HASH, expected $EXPECTED_HASH." \
        "The staged ApiSchema no longer matches what was provisioned into this database." \
        "Reset with 'docker compose down -v' and start again."
fi

log "$STEP_CHECK" "dms.\"EffectiveSchema\" not present, provisioning"

# ------------------------------------------------------------------------------------------------
# Step c: provision. The connection string carries POSTGRES_PASSWORD, so it is only ever passed as
# an argv value to api-schema-tools -- never echoed or logged.
# ------------------------------------------------------------------------------------------------

CONNECTION_STRING="Host=${DB_HOST};Port=${DB_PORT};Database=${POSTGRES_DB_NAME};"
CONNECTION_STRING="${CONNECTION_STRING}Username=postgres;Password=${POSTGRES_PASSWORD}"

api-schema-tools ddl provision \
    --schema "$SCHEMA_FILE" \
    --connection-string "$CONNECTION_STRING" \
    --dialect pgsql \
    --create-database \
    || die "$STEP_PROVISION" "api-schema-tools ddl provision failed"

log "$STEP_PROVISION" "provisioning complete"

# ------------------------------------------------------------------------------------------------
# Step d: verify the stored hash matches what was expected.
# ------------------------------------------------------------------------------------------------

STORED_HASH=$(kit_psql -f - <<'SQL'
SELECT "EffectiveSchemaHash" FROM dms."EffectiveSchema" LIMIT 1;
SQL
)
if [ "$STORED_HASH" != "$EXPECTED_HASH" ]; then
    die "$STEP_VERIFY" \
        "after provisioning, dms.\"EffectiveSchema\" holds hash $STORED_HASH, expected $EXPECTED_HASH"
fi
log "$STEP_VERIFY" "dms.\"EffectiveSchema\" hash verified: $EXPECTED_HASH"
