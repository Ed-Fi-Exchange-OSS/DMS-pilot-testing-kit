#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-template (Tasks 8-9): loads a pinned Data Standard 5.2 template into a fresh database, through
# a throwaway SeedLoader credential created and torn down for this run. DATABASE_TEMPLATE=minimal
# loads descriptors and SchoolYearType only; DATABASE_TEMPLATE=populated adds the DS 5.2 sample data
# (Samples/Sample XML/). A kit-owned marker table records what was loaded, so a rerun is a no-op and a
# changed DATABASE_TEMPLATE without a reset only warns (FR-TMPL-4/5). The marker is written only after
# every step below has succeeded, so a partial failure leaves none and the next start retries from
# scratch.
#
# Runs after DMS is healthy (it loads through the DMS REST API and BulkLoadClient), and after
# init-identity/init-datastore, whose PilotKitAdmin client this script authenticates as.
#
# Source: spike-notes.md Q9 (the Data Standard zip, SchoolYearType precondition, BulkLoadClient
# invocation and timings, the two-tier populated staging) and Q7 (the vendor/application flow, the
# Location-header id, DMS token via Basic auth). GitHub archive zips aren't guaranteed byte-stable, so
# DATA_STANDARD_CONTENT_SHA256 and (populated only) DATA_STANDARD_SAMPLES_SHA256 pin hashes of the
# extracted content, not the zip itself.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_MARKER=marker
STEP_SOURCE=fetch-source
STEP_CREDENTIAL=seed-credential
STEP_TOKEN=dms-token
STEP_SCHOOLYEAR=school-year-types
STEP_LOAD=bulk-load
STEP_VERIFY=verify
STEP_CLEANUP=cleanup

START_EPOCH=$(date +%s)

VENDOR_COMPANY="Pilot Kit Seed Loader"
APPLICATION_NAME="Pilot Kit Seed Loader"
DATASTORE_NAME="Pilot Kit"
# Populated's sample data uses both uri://ed-fi.org and uri://gbisd.edu (spike-notes Q9); the vendor
# always gets both, on both templates, since it's reused across runs and carries no secret.
SEED_NAMESPACE_PREFIXES="uri://ed-fi.org,uri://gbisd.edu"

require_env "$STEP_ENV" \
    DATABASE_TEMPLATE CONFIG_BASE_URL DMS_BASE_URL CMS_ADMIN_CLIENT_SECRET \
    POSTGRES_PASSWORD POSTGRES_DB_NAME \
    DATA_STANDARD_URL DATA_STANDARD_VERSION DATA_STANDARD_CONTENT_SHA256 \
    DATA_STANDARD_SAMPLES_SHA256 POPULATED_SEED_EDORG_IDS

# ------------------------------------------------------------------------------------------------
# Step a: validate DATABASE_TEMPLATE before touching anything else (acceptance case: an invalid value
# fails clearly, with no marker table access and no partial credential setup).
# ------------------------------------------------------------------------------------------------

case "$DATABASE_TEMPLATE" in
    minimal | populated) ;;
    *)
        die "$STEP_ENV" "DATABASE_TEMPLATE must be 'minimal' or 'populated' (got '$DATABASE_TEMPLATE')"
        ;;
esac

export PGHOST="${DB_HOST:-db}"
export PGPORT="${DB_PORT:-5432}"
export PGUSER=postgres
export PGDATABASE="$POSTGRES_DB_NAME"
export PGPASSWORD="$POSTGRES_PASSWORD"

# A private scratch directory for extraction and CMS response bodies. Removed on exit either way.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/init-template.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------------------------
# Step b: the marker. A kit-owned table (schema kit, table initialization) records the template that
# was loaded. No row: proceed to load. Same template: nothing to do (FR-TMPL-4). Different template:
# warn and stop without loading -- the database needs a reset, not a second load layered on top
# (FR-TMPL-5).
# ------------------------------------------------------------------------------------------------

ensure_marker_table() {
    kit_psql -f - <<'SQL'
CREATE SCHEMA IF NOT EXISTS kit;
CREATE TABLE IF NOT EXISTS kit.initialization (
    template TEXT NOT NULL,
    data_standard_version TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SQL
}

check_marker() {
    _cm_row=$(kit_psql -f - <<'SQL'
SELECT template || '|' || data_standard_version || '|' || content_sha256
FROM kit.initialization
ORDER BY completed_at DESC
LIMIT 1;
SQL
)
    [ -n "$_cm_row" ] || return 0

    _cm_existing_template=${_cm_row%%|*}
    if [ "$_cm_existing_template" = "$DATABASE_TEMPLATE" ]; then
        log "$STEP_MARKER" "already initialized with template '$DATABASE_TEMPLATE', skipping"
        exit 0
    fi

    log "$STEP_MARKER" \
        "WARNING: this database was initialized with DATABASE_TEMPLATE='$_cm_existing_template'," \
        "but .env now sets DATABASE_TEMPLATE='$DATABASE_TEMPLATE'. Changing the template on an" \
        "existing database requires a reset: run 'docker compose down -v' and start again." \
        "Leaving the database as it is."
    exit 0
}

ensure_marker_table
check_marker
log "$STEP_MARKER" "no marker found, loading template '$DATABASE_TEMPLATE'"

# ------------------------------------------------------------------------------------------------
# Step c: the source. Download the pinned Data Standard zip into the cache volume (skipped if
# already cached -- a reset via `down -v` also clears the cache, so this only saves a re-download
# after a failed init-template retry), then extract Descriptors/ and Schemas/Bulk/ (plus, for
# populated, "Samples/Sample XML/" -- note the space in that path) and verify the content pin(s)
# before anything downstream trusts them.
# ------------------------------------------------------------------------------------------------

CACHE_DIR="${DATA_STANDARD_CACHE_DIR:-/cache}"
ZIP_FILE="$CACHE_DIR/data-standard-${DATA_STANDARD_VERSION}.zip"

fetch_source() {
    if [ -s "$ZIP_FILE" ]; then
        log "$STEP_SOURCE" "using cached zip at $ZIP_FILE"
    else
        log "$STEP_SOURCE" "downloading Data Standard $DATA_STANDARD_VERSION from $DATA_STANDARD_URL"
        _fs_tmp="$ZIP_FILE.download"
        rm -f "$_fs_tmp"
        if ! kit_curl -L -o "$_fs_tmp" "$DATA_STANDARD_URL"; then
            rm -f "$_fs_tmp"
            die "$STEP_SOURCE" \
                "download of DATA_STANDARD_URL ($DATA_STANDARD_URL) failed or timed out." \
                "Check network access and the URL, then retry; the partial download was removed," \
                "so the next run tries again."
        fi
        mv "$_fs_tmp" "$ZIP_FILE"
    fi

    _fs_top_dir=$(unzip -Z1 "$ZIP_FILE" 2>/dev/null | head -n1)
    _fs_top_dir=${_fs_top_dir%%/*}
    if [ -z "$_fs_top_dir" ]; then
        rm -f "$ZIP_FILE"
        die "$STEP_SOURCE" \
            "could not read a top-level directory from $ZIP_FILE; it may be corrupt or not a zip." \
            "The cached file was removed -- check DATA_STANDARD_URL and retry."
    fi

    EXTRACT_DIR="$WORK_DIR/extracted"
    mkdir -p "$EXTRACT_DIR"
    set -- "$_fs_top_dir/Descriptors/*" "$_fs_top_dir/Schemas/Bulk/*"
    if [ "$DATABASE_TEMPLATE" = "populated" ]; then
        set -- "$@" "$_fs_top_dir/Samples/Sample XML/*"
    fi
    if ! unzip -q -o "$ZIP_FILE" "$@" -d "$EXTRACT_DIR"; then
        rm -f "$ZIP_FILE"
        die "$STEP_SOURCE" \
            "failed to extract the required content from $ZIP_FILE; it may be corrupt." \
            "The cached file was removed -- check DATA_STANDARD_URL and retry."
    fi

    DESCRIPTORS_DIR="$EXTRACT_DIR/$_fs_top_dir/Descriptors"
    BULK_XSD_DIR="$EXTRACT_DIR/$_fs_top_dir/Schemas/Bulk"
    [ -d "$DESCRIPTORS_DIR" ] || die "$STEP_SOURCE" "$_fs_top_dir/Descriptors not found after extraction"
    [ -d "$BULK_XSD_DIR" ] || die "$STEP_SOURCE" "$_fs_top_dir/Schemas/Bulk not found after extraction"

    _fs_actual=$( (cd "$EXTRACT_DIR/$_fs_top_dir" && find Descriptors Schemas/Bulk -type f \
        | LC_ALL=C sort | xargs sha256sum) | sha256sum | awk '{print $1}')
    if [ "$_fs_actual" != "$DATA_STANDARD_CONTENT_SHA256" ]; then
        die "$STEP_SOURCE" \
            "content of DATA_STANDARD_URL ($DATA_STANDARD_URL) does not match" \
            "DATA_STANDARD_CONTENT_SHA256 (got $_fs_actual, expected $DATA_STANDARD_CONTENT_SHA256)." \
            "Delete the cached zip ($ZIP_FILE, or reset the data-standard-cache volume) and retry;" \
            "if the release content legitimately changed, update DATA_STANDARD_CONTENT_SHA256 in .env."
    fi
    log "$STEP_SOURCE" "content pin verified: $_fs_actual"

    if [ "$DATABASE_TEMPLATE" = "populated" ]; then
        SAMPLES_DIR="$EXTRACT_DIR/$_fs_top_dir/Samples/Sample XML"
        [ -d "$SAMPLES_DIR" ] \
            || die "$STEP_SOURCE" "$_fs_top_dir/Samples/Sample XML not found after extraction"

        # The space in "Sample XML" makes a plain `find | sort | xargs` unsafe (word-splitting would
        # break the path into two args); -print0/-z/-0 keep each path NUL-delimited end to end.
        _fs_samples_actual=$( (cd "$EXTRACT_DIR/$_fs_top_dir" \
            && find "Samples/Sample XML" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
            | sha256sum | awk '{print $1}')
        if [ "$_fs_samples_actual" != "$DATA_STANDARD_SAMPLES_SHA256" ]; then
            die "$STEP_SOURCE" \
                "content of Samples/Sample XML in DATA_STANDARD_URL ($DATA_STANDARD_URL) does not" \
                "match DATA_STANDARD_SAMPLES_SHA256 (got $_fs_samples_actual, expected" \
                "$DATA_STANDARD_SAMPLES_SHA256). Delete the cached zip ($ZIP_FILE, or reset the" \
                "data-standard-cache volume) and retry; if the release content legitimately changed," \
                "update DATA_STANDARD_SAMPLES_SHA256 in .env."
        fi
        log "$STEP_SOURCE" "samples pin verified: $_fs_samples_actual"
    fi
}

fetch_source

# ------------------------------------------------------------------------------------------------
# Step c2 (populated only): stage two BulkLoadClient-discoverable tiers out of the extracted content,
# as upstream's New-SeedWorkspace does (dms-compose/load-dms-seed-data.ps1). BulkLoadClient only
# matches Name.xml, Name-*.xml, or Name/*.xml, so every sample file needs a home that fits one of
# those shapes:
#   - descriptor tier: Descriptors/*.xml plus the sample *Descriptor.xml files, with the sample copy
#     overwriting the shipped one on the one collision (DiagnosisDescriptor.xml).
#   - resource tier: every other sample file, nested one level under a directory named for its root
#     element -- root <Interchange<Name>> stages under "<Name>/", confirmed against upstream's
#     Resolve-SeedXmlRootInterchangeName regex (^Interchange(?<name>.+)$) in that same script. Names
#     like AssessmentSample.xml or StudentSchoolAttendance.xml don't already match their interchange
#     (AssessmentMetadata, StudentAttendance), which is exactly why nesting is required.
# The root element is found without an XML parser (the tools image has none): the first element name
# matching <Interchange[A-Za-z]*, which is safe here because no sample file has a comment or other
# element before its root (checked by hand against this pinned Data Standard version).
# ------------------------------------------------------------------------------------------------

stage_populated_tiers() {
    STAGING_DIR="$WORK_DIR/staging"
    RESOURCE_TIER_DIR="$STAGING_DIR/resources"
    _spt_descriptor_tier_dir="$STAGING_DIR/descriptors"
    mkdir -p "$_spt_descriptor_tier_dir" "$RESOURCE_TIER_DIR"

    cp "$DESCRIPTORS_DIR"/*.xml "$_spt_descriptor_tier_dir/"
    _spt_sample_descriptors=0
    for _spt_f in "$SAMPLES_DIR"/*Descriptor.xml; do
        [ -e "$_spt_f" ] || continue
        cp "$_spt_f" "$_spt_descriptor_tier_dir/"
        _spt_sample_descriptors=$((_spt_sample_descriptors + 1))
    done
    DESCRIPTORS_DIR="$_spt_descriptor_tier_dir"
    _spt_descriptor_count=$(find "$DESCRIPTORS_DIR" -maxdepth 1 -type f -name '*.xml' | wc -l)

    _spt_resource_count=0
    for _spt_f in "$SAMPLES_DIR"/*.xml; do
        [ -e "$_spt_f" ] || continue
        case "$(basename "$_spt_f")" in
            *Descriptor.xml) continue ;;
        esac
        # `|| :` -- a no-match `grep -o` exits 1, which would otherwise abort the whole script right
        # here under `set -e` instead of reaching the die below that names the offending file.
        _spt_root=$(grep -o -m1 '<Interchange[A-Za-z]*' "$_spt_f" || :)
        case "$_spt_root" in
            '<Interchange'?*) _spt_interchange=${_spt_root#'<Interchange'} ;;
            *)
                die "$STEP_SOURCE" \
                    "$(basename "$_spt_f") has no <Interchange...> root element;" \
                    "cannot place it in a BulkLoadClient-discoverable resource-tier directory"
                ;;
        esac
        mkdir -p "$RESOURCE_TIER_DIR/$_spt_interchange"
        cp "$_spt_f" "$RESOURCE_TIER_DIR/$_spt_interchange/"
        _spt_resource_count=$((_spt_resource_count + 1))
    done
    _spt_interchange_count=$(find "$RESOURCE_TIER_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)

    log "$STEP_SOURCE" \
        "staged $_spt_descriptor_count descriptor-tier files ($_spt_sample_descriptors from Samples)" \
        "and $_spt_resource_count resource-tier files across $_spt_interchange_count interchanges"
}

if [ "$DATABASE_TEMPLATE" = "populated" ]; then
    stage_populated_tiers
fi

# ------------------------------------------------------------------------------------------------
# Step d: the SeedLoader credential. The vendor is reused across runs (it carries no secret); the
# application is recreated every attempt and deleted after a successful load, so the credential never
# outlives initialization (spike-notes Q7/Q9: SeedLoader has no Read and can write anything). Any
# leftover application from an earlier failed run is deleted first, matched by name and before the
# vendor is touched, so a vendor that needs recreating (cms_ensure_vendor) never has an application
# still pointing at it. Populated needs educationOrganizationIds for the sample LEA, ESC, PSI, and
# community provider (spike-notes Q9); minimal keeps the empty list Task 8 used.
# ------------------------------------------------------------------------------------------------

provision_seed_credential() {
    ADMIN_TOKEN=$(cms_token "$STEP_CREDENTIAL" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" \
        edfi_admin_api/full_access)

    _psc_leftover_ids=$(cms_find_application_ids_by_name \
        "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$APPLICATION_NAME")
    for _psc_leftover_id in $_psc_leftover_ids; do
        _psc_status=$(cms_delete_application "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$_psc_leftover_id")
        case "$_psc_status" in
            2??) log "$STEP_CREDENTIAL" "deleted leftover application $_psc_leftover_id" ;;
            *)
                log "$STEP_CREDENTIAL" \
                    "WARNING: could not delete leftover application $_psc_leftover_id (HTTP $_psc_status)"
                ;;
        esac
    done

    VENDOR_ID=$(cms_ensure_vendor "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$VENDOR_COMPANY" \
        "Pilot Kit Automation" "pilot-kit@example.com" "$SEED_NAMESPACE_PREFIXES")
    log "$STEP_CREDENTIAL" "vendor '$VENDOR_COMPANY' id=$VENDOR_ID"

    DATASTORE_ID=$(cms_find_datastore_id "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$DATASTORE_NAME")

    if [ "$DATABASE_TEMPLATE" = "populated" ]; then
        _psc_edorg_ids_json=$(printf '%s' "$POPULATED_SEED_EDORG_IDS" | jq -R -c 'split(",") | map(tonumber)')
    else
        _psc_edorg_ids_json='[]'
    fi

    _psc_body=$(jq -n \
        --argjson vendorId "$VENDOR_ID" \
        --arg applicationName "$APPLICATION_NAME" \
        --argjson dataStoreId "$DATASTORE_ID" \
        --argjson educationOrganizationIds "$_psc_edorg_ids_json" \
        '{vendorId: $vendorId, applicationName: $applicationName, claimSetName: "SeedLoader",
          educationOrganizationIds: $educationOrganizationIds, dataStoreIds: [$dataStoreId],
          profileIds: []}')
    cms_create_application "$STEP_CREDENTIAL" "$ADMIN_TOKEN" "$_psc_body"
    log "$STEP_CREDENTIAL" \
        "created application '$APPLICATION_NAME' id=$CMS_APPLICATION_ID" \
        "educationOrganizationIds=$_psc_edorg_ids_json"
}

provision_seed_credential

# ------------------------------------------------------------------------------------------------
# Step e: a DMS token for the SeedLoader credential (Basic auth, unlike the CMS system clients).
# ------------------------------------------------------------------------------------------------

DMS_TOKEN=$(dms_token "$STEP_TOKEN" "$DMS_BASE_URL" "$CMS_APPLICATION_KEY" "$CMS_APPLICATION_SECRET")
log "$STEP_TOKEN" "obtained a DMS token for the SeedLoader credential"

# ------------------------------------------------------------------------------------------------
# Step f: SchoolYearType, 1991-2037. v5.x models it as a closed XSD enumeration with no interchange,
# so it is POSTed directly through the REST API before any bulk pass (upstream
# Invoke-SchoolYearTypeRestPrecondition). Re-POST returns 200 (an upsert), so both 200 and 201 are
# accepted -- this step is safe to repeat even though the marker check above normally prevents that.
# ------------------------------------------------------------------------------------------------

current_school_year() {
    _csy_year=$(date +%Y)
    _csy_month=$(date +%m)
    _csy_month=${_csy_month#0} # "09" -> "9": a leading zero would otherwise read as octal in $(( ))
    if [ "$_csy_month" -gt 6 ]; then
        echo $((_csy_year + 1))
    else
        echo "$_csy_year"
    fi
}

seed_school_year_types() {
    _syt_current=$(current_school_year)
    _syt_created=0
    _syt_year=1991
    while [ "$_syt_year" -le 2037 ]; do
        _syt_prev=$((_syt_year - 1))
        if [ "$_syt_year" -eq "$_syt_current" ]; then _syt_is_current=true; else _syt_is_current=false; fi
        _syt_body=$(jq -n --argjson year "$_syt_year" --arg desc "${_syt_prev}-${_syt_year}" \
            --argjson current "$_syt_is_current" \
            '{schoolYear: $year, schoolYearDescription: $desc, currentSchoolYear: $current}')
        _syt_status=$(kit_curl -o /dev/null -w '%{http_code}' \
            --request POST "${DMS_BASE_URL}/data/ed-fi/schoolYearTypes" \
            --header "Authorization: Bearer $DMS_TOKEN" \
            --header "Content-Type: application/json" \
            --data "$_syt_body") \
            || die "$STEP_SCHOOLYEAR" "POST schoolYearTypes for $_syt_year failed or timed out"
        case "$_syt_status" in
            200 | 201) _syt_created=$((_syt_created + 1)) ;;
            *)
                die "$STEP_SCHOOLYEAR" \
                    "POST schoolYearTypes for $_syt_year returned HTTP $_syt_status, expected 200 or 201"
                ;;
        esac
        _syt_year=$((_syt_year + 1))
    done
    log "$STEP_SCHOOLYEAR" "seeded $_syt_created schoolYearTypes rows (1991-2037), current=$_syt_current"
}

seed_school_year_types

# ------------------------------------------------------------------------------------------------
# Step g: BulkLoadClient loads the descriptor tier, then (populated only) the resource tier. `-b` is
# the DMS base including /api; BulkLoadClient reads /api/metadata/specifications and uses the local
# `-x` XSDs instead of downloading them (spike-notes Q9). A non-zero exit fails the step that produced
# it, naming which tier; nothing here parses the console output for a partial-success count, so any
# failure aborts the whole load.
# ------------------------------------------------------------------------------------------------

run_bulk_load() {
    _rbl_tier="$1"
    _rbl_dir="$2"
    _rbl_start=$(date +%s)
    _rbl_work=$(mktemp -d /work/blc.XXXXXX)
    log "$STEP_LOAD" "running BulkLoadClient ($_rbl_tier tier) against $_rbl_dir"
    bulkloadclient -b "$DMS_BASE_URL" -o "${DMS_BASE_URL}/oauth/token" \
        -d "$_rbl_dir" -w "$_rbl_work" \
        -k "$CMS_APPLICATION_KEY" -s "$CMS_APPLICATION_SECRET" \
        -x "$BULK_XSD_DIR" -c 10 -l 10 -t 5 -r 2 \
        || die "$STEP_LOAD" \
            "BulkLoadClient exited non-zero on the $_rbl_tier tier; see the output above for the" \
            "failing file(s)"
    _rbl_elapsed=$(($(date +%s) - _rbl_start))
    log "$STEP_LOAD" "BulkLoadClient completed ($_rbl_tier tier, ${_rbl_elapsed}s)"
}

run_bulk_load descriptor "$DESCRIPTORS_DIR"
if [ "$DATABASE_TEMPLATE" = "populated" ]; then
    run_bulk_load resource "$RESOURCE_TIER_DIR"
fi

# ------------------------------------------------------------------------------------------------
# Step h: verify. SeedLoader has no Read (spike-notes Q7/Q9), so this reads directly from PostgreSQL
# instead of the API. Populated also checks students and schools, in edfi."Student"/edfi."School"
# (relational tables generated from the DS 5.2 ApiSchema -- confirmed by name against a real
# `api-schema-tools ddl emit`/`ddl provision` run, not guessed).
# ------------------------------------------------------------------------------------------------

verify_load() {
    _vl_count=$(kit_psql -f - <<'SQL'
SELECT count(*) FROM dms."Descriptor";
SQL
)
    case "$_vl_count" in
        '' | *[!0-9]*)
            die "$STEP_VERIFY" "could not read a numeric count from dms.\"Descriptor\" (got '$_vl_count')"
            ;;
    esac
    if [ "$_vl_count" -eq 0 ]; then
        die "$STEP_VERIFY" "dms.\"Descriptor\" has 0 rows after loading; expected more than 0"
    fi
    log "$STEP_VERIFY" "dms.\"Descriptor\" has $_vl_count rows (spike baseline: 3303 on a clean minimal load)"

    if [ "$DATABASE_TEMPLATE" = "populated" ]; then
        _vl_student_count=$(kit_psql -f - <<'SQL'
SELECT count(*) FROM edfi."Student";
SQL
)
        case "$_vl_student_count" in
            '' | *[!0-9]*)
                die "$STEP_VERIFY" \
                    "could not read a numeric count from edfi.\"Student\" (got '$_vl_student_count')"
                ;;
        esac
        if [ "$_vl_student_count" -eq 0 ]; then
            die "$STEP_VERIFY" "edfi.\"Student\" has 0 rows after a populated load; expected more than 0"
        fi

        _vl_school_count=$(kit_psql -f - <<'SQL'
SELECT count(*) FROM edfi."School";
SQL
)
        case "$_vl_school_count" in
            '' | *[!0-9]*)
                die "$STEP_VERIFY" \
                    "could not read a numeric count from edfi.\"School\" (got '$_vl_school_count')"
                ;;
        esac

        log "$STEP_VERIFY" \
            "edfi.\"Student\" has $_vl_student_count rows, edfi.\"School\" has $_vl_school_count rows" \
            "(spike baseline: 960 students, 3 schools)"
    fi
}

verify_load

# ------------------------------------------------------------------------------------------------
# Step i: everything succeeded. Write the marker, delete the SeedLoader application (a warning, not a
# failure, if that doesn't work -- see cms_delete_application), and log a summary.
# ------------------------------------------------------------------------------------------------

write_marker() {
    kit_psql -v template="$DATABASE_TEMPLATE" -v ds_version="$DATA_STANDARD_VERSION" \
        -v pin="$DATA_STANDARD_CONTENT_SHA256" -f - <<'SQL'
INSERT INTO kit.initialization (template, data_standard_version, content_sha256, completed_at)
VALUES (:'template', :'ds_version', :'pin', now());
SQL
    log "$STEP_MARKER" "wrote the initialization marker (template=$DATABASE_TEMPLATE)"
}

write_marker

_cleanup_status=$(cms_delete_application "$STEP_CLEANUP" "$ADMIN_TOKEN" "$CMS_APPLICATION_ID")
case "$_cleanup_status" in
    2??) log "$STEP_CLEANUP" "deleted the SeedLoader application ($CMS_APPLICATION_ID)" ;;
    *)
        log "$STEP_CLEANUP" \
            "WARNING: could not delete the SeedLoader application $CMS_APPLICATION_ID" \
            "(HTTP $_cleanup_status). DELETE /v3/applications is unverified against real CMS" \
            "(spike-notes gap) -- remove it manually if this persists."
        ;;
esac

ELAPSED=$(($(date +%s) - START_EPOCH))
if [ "$DATABASE_TEMPLATE" = "populated" ]; then
    log template \
        "done: template=$DATABASE_TEMPLATE dataStandard=$DATA_STANDARD_VERSION" \
        "descriptors=$_vl_count schoolYearTypes=$_syt_created students=$_vl_student_count" \
        "schools=$_vl_school_count elapsed=${ELAPSED}s"
else
    log template \
        "done: template=$DATABASE_TEMPLATE dataStandard=$DATA_STANDARD_VERSION" \
        "descriptors=$_vl_count schoolYearTypes=$_syt_created elapsed=${ELAPSED}s"
fi
