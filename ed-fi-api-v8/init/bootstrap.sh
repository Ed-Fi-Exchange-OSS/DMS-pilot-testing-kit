#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-bootstrap (Task 10): ensures the "Pilot Kit Bootstrap (ADMIN)" vendor and EdFiSandbox
# application exist, writes their key/secret to /runtime/bootstrap-credentials.json (the only place
# the secret is recoverable after creation -- FR-BOOT-6), and creates any missing records from
# bootstrap/baseline-edorgs.json: one SEA, one LEA, and three schools (FR-BOOT-2, FR-EDORG-2/4).
#
# Runs after DMS is healthy (it POSTs baseline records through the DMS REST API) and after
# init-template (the education organization category, grade level, and school category descriptors
# it needs must already exist). Also runnable standalone with `docker compose run --rm
# init-bootstrap` (FR-BOOT-10, Task 12's `bootstrap` script), against either template (FR-EDORG-8:
# the baseline IDs don't collide with the populated template's sample organizations).
#
# Credential handling (FR-BOOT-4/5/6/7):
#   - no application by this name exists                       -> create it, write the file
#   - application exists, file exists and still authenticates  -> reuse both, change nothing
#   - application exists, file missing/invalid/no longer works -> delete the application(s) by
#     this name, recreate, rewrite the file, and warn (the secret was rotated)
# The secret is never logged; only a truncated prefix of the key is, and only when a new one is
# created. See spike-notes.md Q7 (the vendor/application flow, Location-header id, DMS token via
# Basic auth) and Q9 (EdFiSandbox created all five baseline records on both templates).
#
# Baseline records: GET the resource by its natural key first (no upsert endpoint on DMS), and POST
# only if absent, accepting 200 or 201. A missing or corrupt record is recreated on the next run
# without touching the others (FR-BOOT-4/5). Any failure names the resource, its natural key, and the
# HTTP status plus body (FR-BOOT-9).

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_BASELINE_FILE=validate-baseline-file
STEP_TOKEN=cms-token
STEP_CREDENTIAL=bootstrap-credential
STEP_CREDFILE=credentials-file
STEP_DMS_TOKEN=dms-token
STEP_RECORDS=baseline-records
STEP_SUMMARY=summary

START_EPOCH=$(date +%s)

VENDOR_COMPANY="Pilot Kit Bootstrap (ADMIN)"
APPLICATION_NAME="Pilot Kit Bootstrap (ADMIN)"
DATASTORE_NAME="Pilot Kit"
CLAIM_SET_NAME="EdFiSandbox"

require_env "$STEP_ENV" CMS_ADMIN_CLIENT_SECRET CONFIG_BASE_URL DMS_BASE_URL PUBLIC_ORIGIN DMS_PATH_BASE

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
RUNTIME_DIR="${RUNTIME_DIR:-/runtime}"
BASELINE_FILE="$BOOTSTRAP_DIR/baseline-edorgs.json"
CRED_FILE="$RUNTIME_DIR/bootstrap-credentials.json"

# A private scratch directory for request/response bodies. Removed on exit either way.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/init-bootstrap.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------------------------
# Step a: validate baseline-edorgs.json before touching CMS or DMS: a non-empty array of
# {resource, naturalKey, body} entries (the shape init/bootstrap.sh and http/edorgs.http, Task 14,
# both read -- FR-EDORG-14), with at least one stateEducationAgencies entry to scope the credential.
# ------------------------------------------------------------------------------------------------

validate_baseline_file() {
    [ -f "$BASELINE_FILE" ] || die "$STEP_BASELINE_FILE" "$BASELINE_FILE not found"
    jq empty "$BASELINE_FILE" 2>"$WORK_DIR/jq-err" \
        || die "$STEP_BASELINE_FILE" "$BASELINE_FILE is not valid JSON: $(cat "$WORK_DIR/jq-err")"
    jq -e '(type == "array") and (length > 0) and
        (map(has("resource") and has("naturalKey") and has("body")
            and (.resource | type == "string" and length > 0)
            and (.naturalKey | type == "object")
            and (.body | type == "object")) | all)' \
        "$BASELINE_FILE" >/dev/null 2>&1 \
        || die "$STEP_BASELINE_FILE" \
            "$BASELINE_FILE must be a non-empty array of {resource, naturalKey, body} objects"
}

validate_baseline_file

SEA_ID=$(jq -r '[.[] | select(.resource == "stateEducationAgencies")]
    | if length > 0 then (.[0].naturalKey | to_entries[0].value) else empty end' "$BASELINE_FILE")
[ -n "$SEA_ID" ] || die "$STEP_BASELINE_FILE" \
    "no stateEducationAgencies entry in $BASELINE_FILE to scope the bootstrap credential against"

log "$STEP_BASELINE_FILE" "$BASELINE_FILE: $(jq 'length' "$BASELINE_FILE") records, SEA id=$SEA_ID"

ADMIN_TOKEN=$(cms_token "$STEP_TOKEN" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" edfi_admin_api/full_access)

# ------------------------------------------------------------------------------------------------
# Step b: the bootstrap vendor and application. See the file header for the reuse/rotate/create
# decision. BOOT_KEY/BOOT_SECRET/BOOT_APPLICATION_ID are set by whichever branch runs; WRITE_FILE
# records whether step c needs to (re)write bootstrap-credentials.json.
# ------------------------------------------------------------------------------------------------

ensure_bootstrap_credential() {
    _ebc_existing_ids=$(cms_find_application_ids_by_name "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$APPLICATION_NAME")

    _ebc_valid=false
    if [ -n "$_ebc_existing_ids" ] && [ -f "$CRED_FILE" ]; then
        _ebc_file_key=$(jq -r '.key // empty' "$CRED_FILE" 2>/dev/null || true)
        _ebc_file_secret=$(jq -r '.secret // empty' "$CRED_FILE" 2>/dev/null || true)
        if [ -n "$_ebc_file_key" ] && [ -n "$_ebc_file_secret" ] \
            && dms_token_try "$DMS_BASE_URL" "$_ebc_file_key" "$_ebc_file_secret" >/dev/null; then
            _ebc_valid=true
        fi
    fi

    if [ -n "$_ebc_existing_ids" ] && [ "$_ebc_valid" = true ]; then
        BOOT_KEY="$_ebc_file_key"
        BOOT_SECRET="$_ebc_file_secret"
        BOOT_APPLICATION_ID=$(jq -r '.applicationId // empty' "$CRED_FILE")
        [ -n "$BOOT_APPLICATION_ID" ] || BOOT_APPLICATION_ID=$(printf '%s\n' "$_ebc_existing_ids" | head -n1)
        WRITE_FILE=false
        _ebc_key_preview=$(printf '%s' "$BOOT_KEY" | cut -c1-8)
        log "$STEP_CREDENTIAL" \
            "reusing existing bootstrap credential id=$BOOT_APPLICATION_ID key=${_ebc_key_preview}..." \
            "(still authenticates against DMS)"
        return 0
    fi

    if [ -n "$_ebc_existing_ids" ]; then
        log "$STEP_CREDENTIAL" \
            "WARNING: application '$APPLICATION_NAME' exists but $CRED_FILE is missing, invalid, or no" \
            "longer authenticates; rotating -- deleting and recreating the application. Anything using" \
            "the previous key/secret will need the new credentials file."
        for _ebc_id in $_ebc_existing_ids; do
            _ebc_status=$(cms_delete_application "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$_ebc_id")
            case "$_ebc_status" in
                2??) log "$STEP_CREDENTIAL" "deleted application $_ebc_id" ;;
                *) log "$STEP_CREDENTIAL" "WARNING: could not delete application $_ebc_id (HTTP $_ebc_status)" ;;
            esac
        done
    elif [ -f "$CRED_FILE" ]; then
        log "$STEP_CREDENTIAL" \
            "$CRED_FILE exists but no '$APPLICATION_NAME' application is registered in CMS;" \
            "creating a fresh application and overwriting the file"
    fi

    _ebc_vendor_id=$(cms_ensure_vendor "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$VENDOR_COMPANY" \
        "Pilot Kit Automation" "pilot-kit@example.com" "uri://ed-fi.org")
    log "$STEP_CREDENTIAL" "vendor '$VENDOR_COMPANY' id=$_ebc_vendor_id"

    _ebc_datastore_id=$(cms_find_datastore_id "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$DATASTORE_NAME")

    # The SEA (id 99) doesn't exist yet at this point -- education organization scoping in CMS is by
    # id, not by a live reference, so scoping the application ahead of the record it names is fine
    # (spike-notes Q7: the SEA scope reaches its LEA and schools once they exist too).
    _ebc_body=$(jq -n \
        --argjson vendorId "$_ebc_vendor_id" \
        --arg applicationName "$APPLICATION_NAME" \
        --arg claimSetName "$CLAIM_SET_NAME" \
        --argjson dataStoreId "$_ebc_datastore_id" \
        --argjson seaId "$SEA_ID" \
        '{vendorId: $vendorId, applicationName: $applicationName, claimSetName: $claimSetName,
          educationOrganizationIds: [$seaId], dataStoreIds: [$dataStoreId]}')
    cms_create_application "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$_ebc_body"

    BOOT_KEY="$CMS_APPLICATION_KEY"
    BOOT_SECRET="$CMS_APPLICATION_SECRET"
    BOOT_APPLICATION_ID="$CMS_APPLICATION_ID"
    WRITE_FILE=true
    _ebc_key_preview=$(printf '%s' "$BOOT_KEY" | cut -c1-8)
    log "$STEP_CREDENTIAL" \
        "created application '$APPLICATION_NAME' id=$BOOT_APPLICATION_ID key=${_ebc_key_preview}..." \
        "(secret not logged)"
}

ensure_bootstrap_credential

# ------------------------------------------------------------------------------------------------
# Step c: write bootstrap-credentials.json, only when step b created or rotated the credential.
#
# Host permissions: this service runs as user "0:0" (root) because a bind-mounted .runtime/ that
# didn't already exist on the host is created by the Docker daemon as root, which the tools image's
# normal UID 1654 can't write to. After writing, the file (and the directory, if this script had to
# create it) is chowned to the owner of RUNTIME_DIR itself: when Task 12's start script pre-creates
# .runtime/ as the host user before `up`, that ownership is preserved through the bind mount and the
# host user ends up owning the file; when nothing pre-created it, the directory is root-owned and the
# chown is a no-op, which is the documented fallback.
# ------------------------------------------------------------------------------------------------

write_credentials_file() {
    _wcf_created_dir=false
    if [ ! -d "$RUNTIME_DIR" ]; then
        mkdir -p "$RUNTIME_DIR" || die "$STEP_CREDFILE" "could not create $RUNTIME_DIR"
        _wcf_created_dir=true
    fi
    _wcf_owner=$(stat -c '%u:%g' "$RUNTIME_DIR") || die "$STEP_CREDFILE" "could not stat $RUNTIME_DIR"

    _wcf_created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _wcf_token_url="${PUBLIC_ORIGIN}/${DMS_PATH_BASE}/oauth/token"
    _wcf_api_base_url="${PUBLIC_ORIGIN}/${DMS_PATH_BASE}"
    _wcf_warning="ADMIN credential for local testing only. It can create, read, update, and delete \
data anywhere in the hierarchy it is scoped to and is not representative of a production \
integration client (FR-BOOT-7/8). Use a scoped credential from new-credential (Task 13) for \
integration testing; see bootstrap/README.md to rotate or remove this credential (FR-BOOT-13)."

    _wcf_tmp=$(mktemp "$RUNTIME_DIR/.bootstrap-credentials.XXXXXX") \
        || die "$STEP_CREDFILE" "could not create a temp file in $RUNTIME_DIR"

    jq -n \
        --arg key "$BOOT_KEY" \
        --arg secret "$BOOT_SECRET" \
        --arg claimSetName "$CLAIM_SET_NAME" \
        --arg vendorName "$VENDOR_COMPANY" \
        --arg applicationName "$APPLICATION_NAME" \
        --argjson applicationId "$BOOT_APPLICATION_ID" \
        --argjson seaId "$SEA_ID" \
        --arg tokenUrl "$_wcf_token_url" \
        --arg apiBaseUrl "$_wcf_api_base_url" \
        --arg createdAt "$_wcf_created_at" \
        --arg warning "$_wcf_warning" \
        '{key: $key, secret: $secret, claimSetName: $claimSetName, vendorName: $vendorName,
          applicationName: $applicationName, applicationId: $applicationId,
          educationOrganizationIds: [$seaId], tokenUrl: $tokenUrl, apiBaseUrl: $apiBaseUrl,
          createdAt: $createdAt, warning: $warning}' \
        >"$_wcf_tmp" || die "$STEP_CREDFILE" "could not write $_wcf_tmp"

    chmod 600 "$_wcf_tmp" || die "$STEP_CREDFILE" "could not chmod $_wcf_tmp"
    mv "$_wcf_tmp" "$CRED_FILE" || die "$STEP_CREDFILE" "could not move $_wcf_tmp to $CRED_FILE"
    chown "$_wcf_owner" "$CRED_FILE" \
        || log "$STEP_CREDFILE" "WARNING: could not chown $CRED_FILE to $_wcf_owner"
    if [ "$_wcf_created_dir" = true ]; then
        chown "$_wcf_owner" "$RUNTIME_DIR" \
            || log "$STEP_CREDFILE" "WARNING: could not chown $RUNTIME_DIR to $_wcf_owner"
    fi
    log "$STEP_CREDFILE" "wrote $CRED_FILE (mode 600, owner $_wcf_owner)"
}

if [ "$WRITE_FILE" = true ]; then
    write_credentials_file
else
    log "$STEP_CREDFILE" "$CRED_FILE already current, leaving it as-is"
fi

# ------------------------------------------------------------------------------------------------
# Step d: a DMS token for the bootstrap credential (Basic auth -- spike-notes Q7).
# ------------------------------------------------------------------------------------------------

DMS_TOKEN=$(dms_token "$STEP_DMS_TOKEN" "$DMS_BASE_URL" "$BOOT_KEY" "$BOOT_SECRET")
log "$STEP_DMS_TOKEN" "obtained a DMS token for the bootstrap credential"

# ------------------------------------------------------------------------------------------------
# Step e: the baseline records, in the file's order (SEA, then LEA, then the three schools -- every
# reference target already exists by the time it's referenced, FR-EDORG-3). GET by natural key first
# (DMS has no upsert for these resources); POST only if absent, accepting 200 or 201 as success.
# ------------------------------------------------------------------------------------------------

process_baseline_records() {
    _pbr_created=0
    _pbr_existing=0
    _pbr_count=$(jq 'length' "$BASELINE_FILE")
    _pbr_index=0

    while [ "$_pbr_index" -lt "$_pbr_count" ]; do
        _pbr_entry=$(jq -c ".[$_pbr_index]" "$BASELINE_FILE")
        _pbr_resource=$(printf '%s' "$_pbr_entry" | jq -r '.resource')
        _pbr_natural_key=$(printf '%s' "$_pbr_entry" | jq -c '.naturalKey')
        _pbr_body=$(printf '%s' "$_pbr_entry" | jq -c '.body')
        _pbr_key_desc=$(printf '%s' "$_pbr_natural_key" \
            | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        _pbr_query=$(printf '%s' "$_pbr_natural_key" \
            | jq -r 'to_entries | map("\(.key)=\(.value|tostring)") | join("&")')

        _pbr_get_file="$WORK_DIR/get-$_pbr_index.json"
        _pbr_get_status=$(kit_curl -o "$_pbr_get_file" -w '%{http_code}' \
            --request GET "${DMS_BASE_URL}/data/ed-fi/${_pbr_resource}?${_pbr_query}" \
            --header "Authorization: Bearer $DMS_TOKEN") \
            || die "$STEP_RECORDS" "GET $_pbr_resource ($_pbr_key_desc) failed or timed out"

        if [ "$_pbr_get_status" != "200" ]; then
            die "$STEP_RECORDS" \
                "GET $_pbr_resource ($_pbr_key_desc) returned HTTP $_pbr_get_status: $(cat "$_pbr_get_file")"
        fi

        if [ "$(jq 'length > 0' "$_pbr_get_file")" = "true" ]; then
            log "$STEP_RECORDS" "$_pbr_resource ($_pbr_key_desc) already exists, skipping"
            _pbr_existing=$((_pbr_existing + 1))
        else
            _pbr_post_file="$WORK_DIR/post-$_pbr_index.json"
            _pbr_post_status=$(kit_curl -o "$_pbr_post_file" -w '%{http_code}' \
                --request POST "${DMS_BASE_URL}/data/ed-fi/${_pbr_resource}" \
                --header "Authorization: Bearer $DMS_TOKEN" \
                --header "Content-Type: application/json" \
                --data "$_pbr_body") \
                || die "$STEP_RECORDS" "POST $_pbr_resource ($_pbr_key_desc) failed or timed out"

            case "$_pbr_post_status" in
                200 | 201)
                    log "$STEP_RECORDS" "created $_pbr_resource ($_pbr_key_desc)"
                    _pbr_created=$((_pbr_created + 1))
                    ;;
                *)
                    die "$STEP_RECORDS" \
                        "POST $_pbr_resource ($_pbr_key_desc) returned HTTP $_pbr_post_status:" \
                        "$(cat "$_pbr_post_file")"
                    ;;
            esac
        fi
        _pbr_index=$((_pbr_index + 1))
    done

    BASELINE_CREATED=$_pbr_created
    BASELINE_EXISTING=$_pbr_existing
    BASELINE_TOTAL=$_pbr_count
}

process_baseline_records

# ------------------------------------------------------------------------------------------------
# Step f: summary. FR-BOOT-6/7/8: the credentials file path, as seen on the host, and a reminder that
# this is an admin credential, not an integration credential.
# ------------------------------------------------------------------------------------------------

ELAPSED=$(($(date +%s) - START_EPOCH))
log "$STEP_SUMMARY" \
    "baseline records: created=$BASELINE_CREATED existing=$BASELINE_EXISTING (of $BASELINE_TOTAL total)"
log "$STEP_SUMMARY" \
    "bootstrap credential: vendor='$VENDOR_COMPANY' application='$APPLICATION_NAME'" \
    "(id=$BOOT_APPLICATION_ID, claimSetName=$CLAIM_SET_NAME, educationOrganizationIds=[$SEA_ID])"
log "$STEP_SUMMARY" \
    "credentials file: ed-fi-api-v8/.runtime/bootstrap-credentials.json on the host" \
    "-- an ADMIN credential for local testing only; do not use it for integration testing (FR-BOOT-7)"
log "$STEP_SUMMARY" "done in ${ELAPSED}s"
