#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# smoke-test (Task 14, FR-TEST-4): runs the same path as http/smoke.http non-interactively, through
# NGINX (INGRESS_BASE_URL, verified with INGRESS_CA_FILE), so TLS and routing are exercised too, not
# just DMS directly. Called by smoke-test.sh/.ps1 as
#   docker compose run --rm --no-deps --user 0:0 tools sh /init/smoke-test.sh
#
# Unlike the other init/*.sh scripts, this one deliberately does NOT use `set -e`: a smoke test that
# aborted at the first failing step would hide every step after it, defeating the point of a
# checklist. Each step below checks its own status explicitly and records PASS/FAIL/SKIP; the script
# only exits non-zero at the very end, after every step has had a chance to run (the token step is
# the one exception -- nothing after it can run without one, so a token failure is reported and the
# script stops there, still exiting non-zero and printing a summary of what did run).
#
# Steps, in the order http/smoke.http documents them:
#   0. check-edorgs-http.sh (FR-EDORG-14) -- http/edorgs.http must still match baseline-edorgs.json
#   1. token (FR-TEST-2)                    6. cursor paging (FR-FEAT-8)
#   2. Discovery (FR-FEAT-2)                7. change query (FR-FEAT-4)
#   3. descriptor list                      8. ETag If-Match + stale 412 (FR-FEAT-6)
#   4. write + read-back                    9. deliberately invalid POST (FR-TEST-3)
#   5. offset/limit paging (FR-FEAT-7)     10. assessment-style write -- populated only (FR-TEST-7/8)
# Plus two ingress-level checks: the /data/v3 rewrite (Task 6) and the HTTP-to-HTTPS redirect
# (Task 5), both best-effort from inside the Compose network.

set -u

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

require_env smoke-test INGRESS_BASE_URL INGRESS_CA_FILE DMS_PATH_BASE CONFIG_BASE_URL \
    CMS_ADMIN_CLIENT_SECRET POSTGRES_PASSWORD POSTGRES_DB_NAME

RUNTIME_DIR="${RUNTIME_DIR:-/runtime}"
CRED_FILE="$RUNTIME_DIR/bootstrap-credentials.json"
EDORGS_HTTP_FILE="${EDORGS_HTTP_FILE:-/http/edorgs.http}"
SMOKE_BASE="${INGRESS_BASE_URL}/${DMS_PATH_BASE}"
POPULATED_SEED_EDORG_IDS="${POPULATED_SEED_EDORG_IDS:-255901,255950,6000203,19255901}"

[ -r "$INGRESS_CA_FILE" ] || die smoke-test "$INGRESS_CA_FILE not found or not readable"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/smoke-test.XXXXXX")
# shellcheck disable=SC2329,SC2317  # invoked by the trap below
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------------------------
# PASS/FAIL/SKIP bookkeeping.
# ------------------------------------------------------------------------------------------------

STEPS_TOTAL=0
STEPS_FAILED=0
FAILED_STEPS=""

record_pass() {
    _rp_step="$1"
    shift
    STEPS_TOTAL=$((STEPS_TOTAL + 1))
    log "$_rp_step" "PASS: $*"
}

record_fail() {
    _rf_step="$1"
    shift
    STEPS_TOTAL=$((STEPS_TOTAL + 1))
    STEPS_FAILED=$((STEPS_FAILED + 1))
    FAILED_STEPS="$FAILED_STEPS $_rf_step"
    log "$_rf_step" "FAIL: $*"
}

record_skip() {
    _rs_step="$1"
    shift
    STEPS_TOTAL=$((STEPS_TOTAL + 1))
    log "$_rs_step" "SKIP: $*"
}

print_summary_and_exit() {
    _pse_passed=$((STEPS_TOTAL - STEPS_FAILED))
    log summary "$_pse_passed/$STEPS_TOTAL steps passed"
    if [ "$STEPS_FAILED" -gt 0 ]; then
        log summary "failed:$FAILED_STEPS"
        exit 1
    fi
    exit 0
}

# ------------------------------------------------------------------------------------------------
# http_request <method> <url> [curl-args...] -> sets RESP_STATUS, RESP_BODY_FILE, RESP_HEADERS_FILE.
# Always verifies TLS against INGRESS_CA_FILE. Never dies: a request that can't be sent at all (DMS
# or NGINX unreachable) sets RESP_STATUS=000 so the caller can report it as a normal FAIL/step.
# ------------------------------------------------------------------------------------------------

http_request() {
    _hr_method="$1"
    _hr_url="$2"
    shift 2
    RESP_BODY_FILE=$(mktemp "$WORK_DIR/resp-body.XXXXXX")
    RESP_HEADERS_FILE=$(mktemp "$WORK_DIR/resp-headers.XXXXXX")
    RESP_STATUS=$(curl -sS --connect-timeout 10 --max-time 60 --cacert "$INGRESS_CA_FILE" \
        -o "$RESP_BODY_FILE" -D "$RESP_HEADERS_FILE" -w '%{http_code}' \
        --request "$_hr_method" "$_hr_url" "$@") || RESP_STATUS="000"
}

# resp_header <name> -> the last matching response header's value (case-insensitive), or empty.
resp_header() {
    tr -d '\r' <"$RESP_HEADERS_FILE" | grep -i "^$1:" | tail -n1 | sed -E 's/^[^:]+:[[:space:]]*//'
}

# ==================================================================================================
# Step 0: http/edorgs.http vs bootstrap/baseline-edorgs.json (FR-EDORG-14).
# ==================================================================================================

# check-edorgs-http.sh's own log/die lines already carry a "[check-edorgs-http] " prefix (lib.sh's
# log()); strip it before handing the text to record_pass/record_fail, which add their own.
_strip_step_prefix() {
    sed -E 's/^\[check-edorgs-http\] (ERROR: |PASS: )?//' | tr '\n' ' '
}
if EDORGS_HTTP_FILE="$EDORGS_HTTP_FILE" sh "$SCRIPT_DIR/check-edorgs-http.sh" \
    >"$WORK_DIR/check-edorgs-http.out" 2>&1; then
    record_pass check-edorgs-http "$(tail -n1 "$WORK_DIR/check-edorgs-http.out" | _strip_step_prefix)"
else
    record_fail check-edorgs-http "$(_strip_step_prefix <"$WORK_DIR/check-edorgs-http.out")"
fi

# ==================================================================================================
# Step 1: token. Fatal: nothing past this point can run without one.
# ==================================================================================================

[ -f "$CRED_FILE" ] || die bootstrap-credential \
    "$CRED_FILE not found -- run start (or bootstrap) first"
# The file is mode 600, owned by the host user, so the container must run as root (--user 0:0).
[ -r "$CRED_FILE" ] || die bootstrap-credential \
    "$CRED_FILE is not readable by UID $(id -u); run this through smoke-test.sh or .ps1 (--user 0:0)"
BOOT_KEY=$(jq -r '.key // empty' "$CRED_FILE" 2>/dev/null)
BOOT_SECRET=$(jq -r '.secret // empty' "$CRED_FILE" 2>/dev/null)
if [ -z "$BOOT_KEY" ] || [ -z "$BOOT_SECRET" ]; then
    die bootstrap-credential "$CRED_FILE is missing key or secret -- run start (or bootstrap) again"
fi

http_request POST "$SMOKE_BASE/oauth/token" \
    --user "${BOOT_KEY}:${BOOT_SECRET}" --data-urlencode "grant_type=client_credentials"
if [ "$RESP_STATUS" = "503" ]; then
    record_fail token \
        "NGINX returned 503 for $SMOKE_BASE/oauth/token -- DMS appears to be down." \
        "$(jq -r '.detail // empty' "$RESP_BODY_FILE" 2>/dev/null)" \
        "(docker compose ps dms; docker compose logs dms)"
    print_summary_and_exit
fi
if [ "$RESP_STATUS" != "200" ]; then
    record_fail token "POST $SMOKE_BASE/oauth/token returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
    print_summary_and_exit
fi
TOKEN=$(jq -r '.access_token // empty' "$RESP_BODY_FILE" 2>/dev/null)
if [ -z "$TOKEN" ]; then
    record_fail token "POST $SMOKE_BASE/oauth/token returned 200 with no access_token"
    print_summary_and_exit
fi
record_pass token "obtained a bootstrap-credential token through $INGRESS_BASE_URL"
AUTH_HEADER="Authorization: Bearer $TOKEN"

# ==================================================================================================
# Step 2: Discovery.
# ==================================================================================================

http_request GET "$SMOKE_BASE" --header "$AUTH_HEADER"
if [ "$RESP_STATUS" = "200" ] && jq empty "$RESP_BODY_FILE" 2>/dev/null; then
    record_pass discovery "GET $SMOKE_BASE -> 200"
else
    record_fail discovery "GET $SMOKE_BASE returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
fi

# ==================================================================================================
# Step 3: descriptor list.
# ==================================================================================================

http_request GET "$SMOKE_BASE/data/ed-fi/gradeLevelDescriptors?limit=5&totalCount=true" \
    --header "$AUTH_HEADER"
_descriptor_count=$(jq 'length' "$RESP_BODY_FILE" 2>/dev/null || echo 0)
_total_count=$(resp_header Total-Count)
if [ "$RESP_STATUS" = "200" ] && [ "$_descriptor_count" -gt 0 ] 2>/dev/null; then
    record_pass descriptor-list \
        "GET gradeLevelDescriptors -> 200, $_descriptor_count rows, Total-Count=$_total_count"
else
    record_fail descriptor-list \
        "GET gradeLevelDescriptors returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
fi

# ==================================================================================================
# Step 4: write + read-back. FeederSchoolAssociation needs no descriptor and no student, only the
# two baseline schools -- see http/smoke.http for why. DMS upserts by natural key, so this is safe
# to run twice against the same database (idempotent rerun).
# ==================================================================================================

FEEDER_ID=""
FEEDER_ETAG=""
_feeder_body='{"schoolReference":{"schoolId":990003},'
_feeder_body="$_feeder_body"'"feederSchoolReference":{"schoolId":990002},"beginDate":"2024-08-01"}'
http_request POST "$SMOKE_BASE/data/ed-fi/feederSchoolAssociations" \
    --header "$AUTH_HEADER" --header "Content-Type: application/json" --data "$_feeder_body"
case "$RESP_STATUS" in
    200 | 201)
        http_request GET \
            "$SMOKE_BASE/data/ed-fi/feederSchoolAssociations?schoolId=990003&feederSchoolId=990002" \
            --header "$AUTH_HEADER"
        if [ "$RESP_STATUS" = "200" ] && [ "$(jq 'length' "$RESP_BODY_FILE" 2>/dev/null)" = "1" ]; then
            FEEDER_ID=$(jq -r '.[0].id' "$RESP_BODY_FILE")
            FEEDER_ETAG=$(jq -r '.[0]._etag' "$RESP_BODY_FILE")
            record_pass write-read-back "wrote and read back feederSchoolAssociations id=$FEEDER_ID"
        else
            record_fail write-read-back \
                "read-back GET returned HTTP $RESP_STATUS or an unexpected row count:" \
                "$(cat "$RESP_BODY_FILE")"
        fi
        ;;
    *)
        record_fail write-read-back \
            "POST feederSchoolAssociations returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
        ;;
esac

# ==================================================================================================
# Step 5: offset/limit paging with totalCount (FR-FEAT-7).
# ==================================================================================================

NEXT_PAGE_TOKEN=""
http_request GET "$SMOKE_BASE/data/ed-fi/gradeLevelDescriptors?limit=2&offset=2&totalCount=true" \
    --header "$AUTH_HEADER"
_page_total=$(resp_header Total-Count)
NEXT_PAGE_TOKEN=$(resp_header Next-Page-Token)
if [ "$RESP_STATUS" = "200" ] && [ -n "$_page_total" ]; then
    record_pass paging-offset "limit/offset -> 200, Total-Count=$_page_total"
else
    record_fail paging-offset "GET with limit/offset returned HTTP $RESP_STATUS, Total-Count='$_page_total'"
fi

# ==================================================================================================
# Step 6: cursor paging (FR-FEAT-8). The first pageToken must come from a limit= response's
# Next-Page-Token header (step 5, above) or from /partitions -- pageSize alone returns 400.
# ==================================================================================================

if [ -n "$NEXT_PAGE_TOKEN" ]; then
    http_request GET \
        "$SMOKE_BASE/data/ed-fi/gradeLevelDescriptors?pageSize=5&pageToken=$NEXT_PAGE_TOKEN" \
        --header "$AUTH_HEADER"
    if [ "$RESP_STATUS" = "200" ]; then
        record_pass paging-cursor "pageToken from Next-Page-Token -> 200"
    else
        record_fail paging-cursor "GET with pageToken returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
    fi
else
    record_fail paging-cursor "step 5 (paging-offset) returned no Next-Page-Token header to use here"
fi

# ==================================================================================================
# Step 7: change queries (FR-FEAT-4).
# ==================================================================================================

http_request GET "$SMOKE_BASE/changeQueries/v1/availableChangeVersions" --header "$AUTH_HEADER"
_oldest=$(jq -r '.oldestChangeVersion // empty' "$RESP_BODY_FILE" 2>/dev/null)
_newest=$(jq -r '.newestChangeVersion // empty' "$RESP_BODY_FILE" 2>/dev/null)
if [ "$RESP_STATUS" = "200" ] && [ -n "$_oldest" ] && [ -n "$_newest" ]; then
    _change_url="$SMOKE_BASE/data/ed-fi/gradeLevelDescriptors"
    _change_url="${_change_url}?minChangeVersion=${_oldest}&maxChangeVersion=${_newest}&totalCount=true"
    http_request GET "$_change_url" --header "$AUTH_HEADER"
    if [ "$RESP_STATUS" = "200" ]; then
        record_pass change-query "availableChangeVersions=[$_oldest,$_newest], window extract -> 200"
    else
        record_fail change-query \
            "the change-version window GET returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
    fi
else
    record_fail change-query \
        "GET availableChangeVersions returned HTTP $RESP_STATUS: $(cat "$RESP_BODY_FILE")"
fi

# ==================================================================================================
# Step 8: ETag If-Match, plus a stale-ETag 412 (FR-FEAT-6). Needs step 4's write to have succeeded.
# ==================================================================================================

if [ -n "$FEEDER_ID" ] && [ -n "$FEEDER_ETAG" ]; then
    _etag_body=$(jq -n --arg id "$FEEDER_ID" \
        '{id: $id, schoolReference: {schoolId: 990003}, feederSchoolReference: {schoolId: 990002},
          beginDate: "2024-08-01", endDate: "2025-06-30"}')
    http_request PUT "$SMOKE_BASE/data/ed-fi/feederSchoolAssociations/$FEEDER_ID" \
        --header "$AUTH_HEADER" --header "Content-Type: application/json" \
        --header "If-Match: \"$FEEDER_ETAG\"" --data "$_etag_body"
    if [ "$RESP_STATUS" = "204" ]; then
        # The etag used above is now stale (the update above changed it) -- reusing it must 412.
        http_request PUT "$SMOKE_BASE/data/ed-fi/feederSchoolAssociations/$FEEDER_ID" \
            --header "$AUTH_HEADER" --header "Content-Type: application/json" \
            --header "If-Match: \"$FEEDER_ETAG\"" --data "$_etag_body"
        if [ "$RESP_STATUS" = "412" ]; then
            record_pass etag "If-Match with the current ETag -> 204; reusing it -> 412"
        else
            record_fail etag "reusing the stale ETag returned HTTP $RESP_STATUS, expected 412"
        fi
    else
        record_fail etag "PUT with the current If-Match returned HTTP $RESP_STATUS, expected 204"
    fi
else
    record_fail etag "step 4 (write-read-back) did not produce an id/_etag to update here"
fi

# ==================================================================================================
# Step 9: a deliberately invalid POST (FR-TEST-3).
# ==================================================================================================

http_request POST "$SMOKE_BASE/data/ed-fi/schools" \
    --header "$AUTH_HEADER" --header "Content-Type: application/json" \
    --data '{"nameOfInstitution":"Missing required fields on purpose"}'
if [ "$RESP_STATUS" = "400" ]; then
    record_pass invalid-post "POST with missing required fields -> 400"
else
    record_fail invalid-post "POST with missing required fields returned HTTP $RESP_STATUS, expected 400"
fi

# ==================================================================================================
# Step 10: assessment-style reference write, populated template only (FR-TEST-7/8). Detect the
# template from the kit.initialization marker (kit_psql), falling back to DATABASE_TEMPLATE.
# ==================================================================================================

detect_template() {
    export PGHOST="${DB_HOST:-db}"
    export PGPORT="${DB_PORT:-5432}"
    export PGUSER=postgres
    export PGDATABASE="$POSTGRES_DB_NAME"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    _dt_row=$(kit_psql -f - 2>/dev/null <<'SQL'
SELECT template FROM kit.initialization ORDER BY completed_at DESC LIMIT 1;
SQL
)
    if [ -n "${_dt_row:-}" ]; then
        printf '%s' "$_dt_row"
    else
        printf '%s' "${DATABASE_TEMPLATE:-minimal}"
    fi
}

TEMPLATE=$(detect_template)

if [ "$TEMPLATE" != "populated" ]; then
    record_skip assessment-write "requires populated (detected template: $TEMPLATE)"
else
    # The bootstrap credential is scoped to SEA 99 only and cannot see the populated sample
    # hierarchy (bootstrap/README.md), so this step provisions its own throwaway, properly scoped
    # AssessmentVendor credential -- exactly what new-credential --shape assessment (Task 13) would
    # create -- against the sample LEA, uses it once, then deletes it again.
    _assess_edorg_id=$(printf '%s' "$POPULATED_SEED_EDORG_IDS" | cut -d, -f1)
    _assess_name="Pilot Kit Smoke Test (Assessment)"
    _assess_ok=false
    _admin_token=$(cms_token assessment-write PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" \
        edfi_admin_api/full_access 2>"$WORK_DIR/assess-token.err") || {
        record_fail assessment-write \
            "could not get a PilotKitAdmin CMS token: $(cat "$WORK_DIR/assess-token.err")"
        _admin_token=""
    }

    if [ -n "$_admin_token" ]; then
        _old_ids=$(cms_find_application_ids_by_name assessment-write "$_admin_token" "$_assess_name")
        for _old_id in $_old_ids; do
            cms_delete_application assessment-write "$_admin_token" "$_old_id" >/dev/null
        done
        _assess_vendor_id=$(cms_ensure_vendor assessment-write "$_admin_token" "$_assess_name" \
            "Pilot Kit Automation" "pilot-kit@example.com" "uri://ed-fi.org,uri://gbisd.edu")
        _assess_datastore_id=$(cms_find_datastore_id assessment-write "$_admin_token" "Pilot Kit")
        _assess_body=$(jq -n \
            --argjson vendorId "$_assess_vendor_id" \
            --arg applicationName "$_assess_name" \
            --argjson edorgId "$_assess_edorg_id" \
            --argjson dataStoreId "$_assess_datastore_id" \
            '{vendorId: $vendorId, applicationName: $applicationName, claimSetName: "AssessmentVendor",
              educationOrganizationIds: [$edorgId], dataStoreIds: [$dataStoreId]}')
        cms_create_application assessment-write "$_admin_token" "$_assess_body"
        _assess_key="$CMS_APPLICATION_KEY"
        _assess_secret="$CMS_APPLICATION_SECRET"
        _assess_app_id="$CMS_APPLICATION_ID"

        http_request POST "$SMOKE_BASE/oauth/token" \
            --user "${_assess_key}:${_assess_secret}" --data-urlencode "grant_type=client_credentials"
        _assess_token=$(jq -r '.access_token // empty' "$RESP_BODY_FILE" 2>/dev/null)

        if [ "$RESP_STATUS" = "200" ] && [ -n "$_assess_token" ]; then
            http_request GET "$SMOKE_BASE/data/ed-fi/students?limit=1" \
                --header "Authorization: Bearer $_assess_token"
            _student_id=$(jq -r '.[0].studentUniqueId // empty' "$RESP_BODY_FILE" 2>/dev/null)

            if [ "$RESP_STATUS" = "200" ] && [ -n "$_student_id" ]; then
                http_request GET \
                    "$SMOKE_BASE/data/ed-fi/schools?localEducationAgencyId=$_assess_edorg_id&limit=1" \
                    --header "Authorization: Bearer $_assess_token"
                _school_id=$(jq -r '.[0].schoolId // empty' "$RESP_BODY_FILE" 2>/dev/null)

                if [ "$RESP_STATUS" = "200" ] && [ -n "$_school_id" ]; then
                    _ssa_body=$(jq -n \
                        --arg studentUniqueId "$_student_id" \
                        --argjson schoolId "$_school_id" \
                        '{studentReference: {studentUniqueId: $studentUniqueId},
                          schoolReference: {schoolId: $schoolId}, entryDate: "2024-08-01",
                          entryGradeLevelDescriptor: "uri://ed-fi.org/GradeLevelDescriptor#Kindergarten"}')
                    http_request POST "$SMOKE_BASE/data/ed-fi/studentSchoolAssociations" \
                        --header "Authorization: Bearer $_assess_token" \
                        --header "Content-Type: application/json" --data "$_ssa_body"
                    case "$RESP_STATUS" in
                        200 | 201)
                            record_pass assessment-write \
                                "wrote studentSchoolAssociations for an existing student ($_student_id)" \
                                "and school ($_school_id) it did not create"
                            _assess_ok=true
                            ;;
                        *)
                            record_fail assessment-write \
                                "POST studentSchoolAssociations returned HTTP $RESP_STATUS:" \
                                "$(cat "$RESP_BODY_FILE")"
                            ;;
                    esac
                else
                    record_fail assessment-write \
                        "could not find a sample school under LEA $_assess_edorg_id (HTTP $RESP_STATUS)"
                fi
            else
                record_fail assessment-write \
                    "could not find a sample student under LEA $_assess_edorg_id (HTTP $RESP_STATUS)"
            fi
        else
            record_fail assessment-write \
                "could not get a token for the throwaway assessment credential (HTTP $RESP_STATUS)"
        fi

        _cleanup_status=$(cms_delete_application assessment-write "$_admin_token" "$_assess_app_id")
        case "$_cleanup_status" in
            2??) ;;
            *)
                log assessment-write \
                    "WARNING: could not delete throwaway application $_assess_app_id" \
                    "(HTTP $_cleanup_status)"
                ;;
        esac
    fi
fi

# ==================================================================================================
# Ingress checks: the /data/v3 rewrite (Task 6) and the HTTP-to-HTTPS redirect (Task 5). Both are
# best-effort, from inside the Compose network the tools container shares with nginx.
#
# DATA_V3_REWRITE_ENABLED itself is not part of the tools service's environment (compose.init.yml),
# so this infers the setting from NGINX's own behavior instead of reading the flag directly: when
# disabled, 40-kit-features.sh (nginx/entrypoint.d) serves a distinctive
# "urn:ed-fi:kit:data-v3-rewrite-disabled" 404 body for every /data/v3/* request.
# ==================================================================================================

http_request GET "$SMOKE_BASE/data/ed-fi/gradeLevelDescriptors?limit=1" --header "$AUTH_HEADER"
_native_status="$RESP_STATUS"
http_request GET "${INGRESS_BASE_URL}/data/v3/ed-fi/gradeLevelDescriptors?limit=1" --header "$AUTH_HEADER"
_data_v3_type=$(jq -r '.type // empty' "$RESP_BODY_FILE" 2>/dev/null)
if [ "$_data_v3_type" = "urn:ed-fi:kit:data-v3-rewrite-disabled" ]; then
    record_pass data-v3-rewrite "disabled (DATA_V3_REWRITE_ENABLED=false): /data/v3/... -> 404 as expected"
elif [ "$RESP_STATUS" = "$_native_status" ]; then
    record_pass data-v3-rewrite "enabled: /data/v3/... -> HTTP $RESP_STATUS, matching the native path"
else
    record_fail data-v3-rewrite \
        "/data/v3/... returned HTTP $RESP_STATUS, native path returned HTTP $_native_status -- neither" \
        "matches nor looks like the disabled-rewrite 404"
fi

_http_redirect_url="${HTTP_REDIRECT_URL:-http://nginx/}"
http_request GET "$_http_redirect_url"
_redirect_location=$(resp_header Location)
if [ "$RESP_STATUS" = "301" ] && printf '%s' "$_redirect_location" | grep -q '^https://'; then
    record_pass http-redirect "$_http_redirect_url -> 301 $_redirect_location"
else
    record_fail http-redirect \
        "$_http_redirect_url returned HTTP $RESP_STATUS, Location='$_redirect_location'," \
        "expected a 301 to https://"
fi

print_summary_and_exit
