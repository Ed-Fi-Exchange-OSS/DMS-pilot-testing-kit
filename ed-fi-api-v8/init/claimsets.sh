#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-claimsets (Task 11): imports every claim set file in bootstrap/claimsets/ (today, just
# DataWarehouse.json -- see bootstrap/claimsets/README.md) into CMS with POST /v3/claimSets/import.
# Runs after init-identity (for the PilotKitAdmin token) and before DMS starts (compose.core.yml adds
# it to dms.depends_on): a claim set imported while DMS is already running returns HTTP 500 "No
# security metadata has been configured for this resource" until DMS's claim-set cache refreshes, up
# to ClaimSetsCacheExpirationSeconds (600s, spike-notes Q6/Q9). Importing before DMS's first request
# avoids that window entirely.
#
# Idempotent by name: GET /v3/claimSets first. Absent -> import. Present and identical (compared in
# normalized form -- see canonicalize() below) -> skip. Present and different -> re-import (the
# spike proved /v3/claimSets/import is an upsert by id in this build), then call DMS's claim-set
# reload endpoint (Task 18, below) so a *running* DMS picks up the change immediately. Present and
# system-reserved -> fail; this script must never alter one of the 14 embedded claim sets
# (FR-CLAIM-5..8).
#
# FR-CLAIM-14: after importing (new or changed), calls DMS's POST .../management/reload-
# claimsets with the PilotKitAdmin token above so the change is usable at once instead of waiting up
# to 10 minutes for DMS's cache. Skipped, with a log line, when DMS_CLAIMSET_RELOAD_ENABLED is not
# true or DMS is not reachable (the normal case on a clean first start: this service runs before DMS
# starts, per compose.core.yml). A reload DMS actually answers and rejects fails the step (FR-BOOT-9).
#
# CONFIG_BASE_URL, CLAIMSETS_DIR, DMS_BASE_URL, and DMS_HEALTH_URL default to the compose values but
# are overridable, so this script can be pointed at a stub CMS/DMS and a local directory for testing
# without a container.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_TOKEN=cms-token
STEP_VALIDATE=validate-file
STEP_LIST=list-existing
STEP_CHECK=check-existing
STEP_COMPARE=compare-existing
STEP_IMPORT=import
STEP_RELOAD=reload-claimset

require_env "$STEP_ENV" CMS_ADMIN_CLIENT_SECRET
CONFIG_BASE_URL="${CONFIG_BASE_URL:-http://config:8081}"
CLAIMSETS_DIR="${CLAIMSETS_DIR:-/claimsets}"
DMS_CLAIMSET_RELOAD_ENABLED="${DMS_CLAIMSET_RELOAD_ENABLED:-true}"
DMS_BASE_URL="${DMS_BASE_URL:-http://dms:8080/api}"
DMS_HEALTH_URL="${DMS_HEALTH_URL:-http://dms:8080/health}"

[ -d "$CLAIMSETS_DIR" ] || die "$STEP_ENV" "$CLAIMSETS_DIR is not a directory"

# A private scratch directory for request/response bodies. Removed on exit either way.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/init-claimsets.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

TOKEN=$(cms_token "$STEP_TOKEN" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" edfi_admin_api/full_access)

# ------------------------------------------------------------------------------------------------
# canonicalize <file> -> normalized {claimSetName, resourceClaims[...]} on stdout, so an import body
# and a GET .../export response can be diffed even though the export adds fields the import never
# sent (top-level id/_isSystemReserved/_applications; per-claim _defaultAuthorizationStrategies) and
# reorders arrays, and even though CMS's own AuthorizationStrategyListJsonConverter writes
# "authStrategyName" on the way out but accepts "name" on the way in. `-S` sorts object keys so
# construction-order differences never show up as a diff; sort_by handles array order.
# ------------------------------------------------------------------------------------------------

CANON_FILTER='
def canon_claim:
  {
    claimName: .claimName,
    name: .name,
    parentClaimName: .parentClaimName,
    actions: ((.actions // []) | map({name, enabled}) | sort_by(.name)),
    authorizationStrategyOverrides: (
      (.authorizationStrategyOverrides // []) | map({
        actionName,
        authorizationStrategies:
          ((.authorizationStrategies // []) | map({name: (.name // .authStrategyName)}) | sort_by(.name))
      }) | sort_by(.actionName)
    )
  };
{ claimSetName, resourceClaims: ((.resourceClaims // []) | map(canon_claim) | sort_by(.claimName)) }
'

canonicalize() {
    jq -S "$CANON_FILTER" "$1"
}

# ------------------------------------------------------------------------------------------------
# list_claim_sets -> refreshes $WORK_DIR/claimsets-list.json with the current GET /v3/claimSets.
# Called once before each file, so an import earlier in this loop is visible to the next file's
# existence check.
# ------------------------------------------------------------------------------------------------

CLAIMSETS_LIST="$WORK_DIR/claimsets-list.json"

list_claim_sets() {
    _lc_status=$(kit_curl -o "$CLAIMSETS_LIST" -w '%{http_code}' \
        --request GET "${CONFIG_BASE_URL}/v3/claimSets?limit=500" \
        --header "Authorization: Bearer $TOKEN") \
        || die "$STEP_LIST" "GET /v3/claimSets failed or timed out"
    if [ "$_lc_status" != "200" ]; then
        die "$STEP_LIST" "GET /v3/claimSets returned HTTP $_lc_status: $(cat "$CLAIMSETS_LIST")"
    fi
}

# ------------------------------------------------------------------------------------------------
# import_claim_set <file> -- POST /v3/claimSets/import. Fails, printing the warnings array, on any
# non-empty warnings: that is CMS's runtime signal that a claimName in the file doesn't match a real
# node in the claims hierarchy, which is the guard against a name typed wrong in the JSON.
# ------------------------------------------------------------------------------------------------

import_claim_set() {
    _ic_file="$1"
    _ic_response="$WORK_DIR/import-response.json"
    _ic_status=$(kit_curl -o "$_ic_response" -w '%{http_code}' \
        --request POST "${CONFIG_BASE_URL}/v3/claimSets/import" \
        --header "Authorization: Bearer $TOKEN" \
        --header "Content-Type: application/json" \
        --data @"$_ic_file") \
        || die "$STEP_IMPORT" "POST /v3/claimSets/import for $(basename "$_ic_file") failed or timed out"

    if [ "$_ic_status" != "201" ]; then
        die "$STEP_IMPORT" \
            "POST /v3/claimSets/import for $(basename "$_ic_file") returned HTTP $_ic_status:" \
            "$(cat "$_ic_response")"
    fi

    _ic_warnings=$(jq -c '.warnings // []' "$_ic_response")
    if [ "$_ic_warnings" != "[]" ]; then
        die "$STEP_IMPORT" \
            "POST /v3/claimSets/import for $(basename "$_ic_file") returned warnings: $_ic_warnings"
    fi
}

# ------------------------------------------------------------------------------------------------
# reload_claim_set_if_running <claim_set_name> -- Task 18 (FR-CLAIM-14). Forces DMS to drop its
# up-to-10-minute claim-set cache (ClaimSetsCacheExpirationSeconds, spike-notes Q6/Q9) right after an
# import, so the caller's claim set is usable at once. Uses the PilotKitAdmin token already obtained
# above ($TOKEN): DMS validates it the same way it validates a data-request bearer token (both trust
# CMS's issuer/audience/signing key), and PilotKitAdmin carries the role
# AppSettings__ManagementEndpoints__RequiredRole requires (init/identity.sh).
#
# Never dies for "DMS isn't up" -- that is the normal case on a clean first start, since compose.
# core.yml runs this service before DMS starts. Any other non-200 (401/403 from a misconfigured
# role, or a real server error) fails the step: a reload DMS actually answered and refused means the
# claim set change did not take effect, which the caller must not silently report as success.
# ------------------------------------------------------------------------------------------------

reload_claim_set_if_running() {
    _rc_name="$1"

    if [ "$DMS_CLAIMSET_RELOAD_ENABLED" != "true" ]; then
        log "$STEP_RELOAD" "skipped for '$_rc_name': DMS_CLAIMSET_RELOAD_ENABLED is not true"
        return 0
    fi

    _rc_health_status=$(kit_curl -o /dev/null -w '%{http_code}' "$DMS_HEALTH_URL" 2>/dev/null) \
        || _rc_health_status=000
    if [ "$_rc_health_status" != "200" ]; then
        log "$STEP_RELOAD" \
            "skipped for '$_rc_name': DMS is not reachable at $DMS_HEALTH_URL (HTTP $_rc_health_status)." \
            "Expected on a clean first start (init-claimsets runs before dms, compose.core.yml); the" \
            "up-to-10-minute cache window never opens because the claim set predates DMS's first request."
        return 0
    fi

    _rc_response="$WORK_DIR/reload-response.json"
    _rc_status=$(kit_curl -o "$_rc_response" -w '%{http_code}' \
        --request POST "${DMS_BASE_URL}/management/reload-claimsets" \
        --header "Authorization: Bearer $TOKEN") \
        || die "$STEP_RELOAD" \
            "POST ${DMS_BASE_URL}/management/reload-claimsets for '$_rc_name' failed or timed out"

    if [ "$_rc_status" != "200" ]; then
        die "$STEP_RELOAD" \
            "POST ${DMS_BASE_URL}/management/reload-claimsets for '$_rc_name' returned HTTP" \
            "$_rc_status, expected 200: $(cat "$_rc_response")"
    fi

    log "$STEP_RELOAD" "claim set '$_rc_name' reloaded; usable immediately"
}

# ------------------------------------------------------------------------------------------------
# process_file <file>: validate, then decide absent/identical/different/system-reserved.
# ------------------------------------------------------------------------------------------------

process_file() {
    _pf_file="$1"
    _pf_name=$(basename "$_pf_file")

    # Step a: the file must at least be valid JSON with a claimSetName and a resourceClaims array.
    if ! jq empty "$_pf_file" 2>"$WORK_DIR/jq-err"; then
        die "$STEP_VALIDATE" "$_pf_name is not valid JSON: $(cat "$WORK_DIR/jq-err")"
    fi
    jq -e 'has("claimSetName") and (.claimSetName | type == "string" and length > 0)
        and has("resourceClaims") and (.resourceClaims | type == "array")' \
        "$_pf_file" >/dev/null 2>&1 \
        || die "$STEP_VALIDATE" "$_pf_name must have a non-empty claimSetName and a resourceClaims array"

    _pf_claim_set_name=$(jq -r '.claimSetName' "$_pf_file")

    # Step b: does a claim set with this name already exist?
    list_claim_sets
    _pf_id=$(jq -r --arg n "$_pf_claim_set_name" \
        '([.[]? | select(.claimSetName == $n)] | .[0].id) // empty' "$CLAIMSETS_LIST")

    if [ -z "$_pf_id" ]; then
        log "$STEP_CHECK" "claim set '$_pf_claim_set_name' not found, importing from $_pf_name"
        import_claim_set "$_pf_file"
        log "$STEP_IMPORT" "imported claim set '$_pf_claim_set_name' from $_pf_name"
        reload_claim_set_if_running "$_pf_claim_set_name"
        return 0
    fi

    _pf_reserved=$(jq -r --arg n "$_pf_claim_set_name" \
        '([.[]? | select(.claimSetName == $n)] | .[0]._isSystemReserved) // false' "$CLAIMSETS_LIST")
    if [ "$_pf_reserved" = "true" ]; then
        die "$STEP_CHECK" \
            "claim set '$_pf_claim_set_name' already exists and is system-reserved;" \
            "refusing to overwrite one of the embedded claim sets (FR-CLAIM-5..8)"
    fi

    # Step c: compare the existing claim set (exported) to the file, in normalized form.
    _pf_export="$WORK_DIR/export-response.json"
    _pf_status=$(kit_curl -o "$_pf_export" -w '%{http_code}' \
        --request GET "${CONFIG_BASE_URL}/v3/claimSets/${_pf_id}/export" \
        --header "Authorization: Bearer $TOKEN") \
        || die "$STEP_COMPARE" "GET /v3/claimSets/$_pf_id/export failed or timed out"
    if [ "$_pf_status" != "200" ]; then
        die "$STEP_COMPARE" "GET /v3/claimSets/$_pf_id/export returned HTTP $_pf_status: $(cat "$_pf_export")"
    fi

    canonicalize "$_pf_file" >"$WORK_DIR/canon-file.json"
    canonicalize "$_pf_export" >"$WORK_DIR/canon-export.json"
    if diff -q "$WORK_DIR/canon-file.json" "$WORK_DIR/canon-export.json" >/dev/null 2>&1; then
        log "$STEP_COMPARE" "claim set '$_pf_claim_set_name' already matches $_pf_name, skipping"
        return 0
    fi

    log "$STEP_COMPARE" "claim set '$_pf_claim_set_name' differs from $_pf_name, re-importing"
    import_claim_set "$_pf_file"
    log "$STEP_IMPORT" "re-imported claim set '$_pf_claim_set_name' from $_pf_name"
    reload_claim_set_if_running "$_pf_claim_set_name"
}

# ------------------------------------------------------------------------------------------------
# Every *.json file in CLAIMSETS_DIR, in name order for deterministic logs.
# ------------------------------------------------------------------------------------------------

FILES_LIST="$WORK_DIR/files-list.txt"
find "$CLAIMSETS_DIR" -maxdepth 1 -type f -name '*.json' | sort >"$FILES_LIST"

[ -s "$FILES_LIST" ] || die "$STEP_ENV" "no *.json files found in $CLAIMSETS_DIR"

while IFS= read -r CLAIMSET_FILE; do
    process_file "$CLAIMSET_FILE"
done <"$FILES_LIST"
