#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-datastore (Task 4): registers the kit's PostgreSQL data store with CMS. Without one, DMS
# exits in a restart loop at startup (spike-notes Q4: "DMS cannot start without proper data store
# configuration"). Runs after init-identity (tools image), which is where the PilotKitAdmin client
# this script authenticates as gets created.
#
# Idempotent by name: GET /v3/dataStores first, and only POST if "Pilot Kit" isn't already there --
# there is no upsert endpoint. Registering again with a changed POSTGRES_PASSWORD does *not* update
# an existing data store: CMS stores the connection string encrypted, so a rotated password needs a
# reset (docker compose down -v) rather than a re-run of this script.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_TOKEN=cms-token
STEP_CHECK=check-existing
STEP_REGISTER=register

DATASTORE_NAME="Pilot Kit"

require_env "$STEP_ENV" \
    CMS_ADMIN_CLIENT_SECRET CONFIG_BASE_URL \
    POSTGRES_PASSWORD POSTGRES_DB_NAME DMS_DB_MAX_POOL_SIZE

# A private scratch directory: the GET/POST response bodies and the request body (which carries
# POSTGRES_PASSWORD) all live here, never in a log line, and are removed on exit either way.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/init-datastore.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

TOKEN=$(cms_token "$STEP_TOKEN" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" edfi_admin_api/full_access)

# ------------------------------------------------------------------------------------------------
# Step a: does a data store named "Pilot Kit" already exist? GET-before-POST, since CMS has no
# upsert for this resource (spike-notes Q4).
# ------------------------------------------------------------------------------------------------

datastore_exists() {
    _de_list_file="$WORK_DIR/datastores-list.json"
    _de_status=$(kit_curl -o "$_de_list_file" -w '%{http_code}' \
        --request GET "${CONFIG_BASE_URL}/v3/dataStores" \
        --header "Authorization: Bearer $TOKEN") \
        || die "$STEP_CHECK" "GET /v3/dataStores failed or timed out"

    if [ "$_de_status" != "200" ]; then
        die "$STEP_CHECK" "GET /v3/dataStores returned HTTP $_de_status: $(cat "$_de_list_file")"
    fi

    jq -e --arg name "$DATASTORE_NAME" 'any(.[]?; .name == $name)' "$_de_list_file" >/dev/null 2>&1
}

if datastore_exists; then
    log "$STEP_CHECK" "data store '$DATASTORE_NAME' already registered, skipping"
    exit 0
fi
log "$STEP_CHECK" "data store '$DATASTORE_NAME' not found, registering"

# ------------------------------------------------------------------------------------------------
# Step b: register it. `provider` must be lowercase ("postgresql", not "PostgreSQL" -- spike-notes
# Q4). The pool size feeds Npgsql's "Maximum Pool Size", not the CMS pool sizing.
# ------------------------------------------------------------------------------------------------

CONNECTION_STRING="host=db;port=5432;username=postgres;password=${POSTGRES_PASSWORD};"
CONNECTION_STRING="${CONNECTION_STRING}database=${POSTGRES_DB_NAME};"
CONNECTION_STRING="${CONNECTION_STRING}Maximum Pool Size=${DMS_DB_MAX_POOL_SIZE};"

BODY_FILE="$WORK_DIR/register-body.json"
jq -n \
    --arg name "$DATASTORE_NAME" \
    --arg dataStoreType "Development" \
    --arg provider "postgresql" \
    --arg connectionString "$CONNECTION_STRING" \
    '{name: $name, dataStoreType: $dataStoreType, provider: $provider, connectionString: $connectionString}' \
    >"$BODY_FILE"

RESPONSE_FILE="$WORK_DIR/register-response.json"
STATUS=$(kit_curl -o "$RESPONSE_FILE" -w '%{http_code}' \
    --request POST "${CONFIG_BASE_URL}/v3/dataStores" \
    --header "Authorization: Bearer $TOKEN" \
    --header "Content-Type: application/json" \
    --data @"$BODY_FILE") \
    || die "$STEP_REGISTER" "POST /v3/dataStores failed or timed out"

if [ "$STATUS" != "201" ]; then
    die "$STEP_REGISTER" "POST /v3/dataStores returned HTTP $STATUS: $(cat "$RESPONSE_FILE")"
fi

log "$STEP_REGISTER" "registered data store '$DATASTORE_NAME'"
