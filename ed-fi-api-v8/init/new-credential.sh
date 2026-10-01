#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# new-credential (Task 13): registers a fresh vendor and application in CMS for one participant
# integration credential, and writes /runtime/credentials/<name>.json. Unlike init-bootstrap's single
# ADMIN credential, this runs once per participant credential, on demand, via the host wrappers
# (`new-credential.sh`/`.ps1`) or directly as
# `docker compose run --rm --no-deps --user 0:0 tools sh /init/new-credential.sh ...` (FR-CRED-1).
#
# --shape selects the standard claim set (sis -> SISVendor, assessment -> AssessmentVendor,
# warehouse -> DataWarehouse, the kit addition from Task 11), overridable with --claim-set, which is
# rejected unless GET /v3/claimSets already lists it (FR-CLAIM-10). --edorg-ids overrides the default
# scoping; the default comes from the template actually loaded (read from the kit.initialization
# marker, spike-notes Q7/Q9): the bootstrapped SEA (99) on minimal, the sample LEA (255901) on
# populated, or [] for warehouse credentials, which read everything unscoped (decision 6, plan.md) so
# FR-CRED-9 doesn't apply to them (FR-CRED-4/7/8/9/10).
#
# --name must be unique: this script never overwrites an existing application or credentials file
# (FR-CRED-3). Vendor, application, and file creation only start after that check passes, so a
# rejected name leaves nothing behind.
#
# After creating the application, the credentials file is written first (so the secret, shown only
# once by CMS, is never lost even if the verification step below fails), then a DMS token and one
# shape-appropriate GET are attempted through the same NGINX ingress a participant uses, proving the
# credential works with no extra configuration (FR-CRED-1). A 401 is retried a few times with backoff
# (the spike saw none, but keeps the door open for a slow first request); any other failure leaves the
# credential and file in place and is reported clearly, and this script then exits non-zero.
#
# The key and secret are printed to stdout exactly once, deliberately (FR-CRED-2); every other line
# this script produces goes through log()/die() to stderr, and the secret is never logged there.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ARGS=validate-args
STEP_READY=cms-ready
STEP_TOKEN=cms-token
STEP_UNIQUE=uniqueness
STEP_TEMPLATE=template
STEP_CLAIMSET=claim-set
STEP_EDORGS=edorg-ids
STEP_VENDOR=vendor
STEP_APP=application
STEP_WRITE=credentials-file
STEP_VERIFY=verify

usage() {
    cat <<'EOF'
Usage: new-credential.sh --shape sis|assessment|warehouse --name <name>
                          [--claim-set <name>] [--edorg-ids 1,2,3]

  --shape       Required. sis -> SISVendor, assessment -> AssessmentVendor, warehouse -> DataWarehouse.
  --name        Required. Unique. Letters, digits, '.', '_', '-' only; 1-64 characters.
  --claim-set   Optional override of the claim set implied by --shape. Must already exist in CMS.
  --edorg-ids   Optional comma-separated education organization ids. Defaults depend on --shape and
                the loaded template: the bootstrapped SEA on minimal, the sample LEA on populated, or
                none for warehouse credentials.
EOF
}

# ------------------------------------------------------------------------------------------------
# Step a: parse and validate arguments before any network or database call, so a typo is reported at
# once and never has a side effect.
# ------------------------------------------------------------------------------------------------

SHAPE=""
NAME=""
CLAIM_SET_ARG=""
EDORG_IDS_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --shape)
            [ $# -ge 2 ] || die "$STEP_ARGS" "--shape requires a value"
            SHAPE="$2"
            shift 2
            ;;
        --shape=*) SHAPE="${1#*=}" && shift ;;
        --name)
            [ $# -ge 2 ] || die "$STEP_ARGS" "--name requires a value"
            NAME="$2"
            shift 2
            ;;
        --name=*) NAME="${1#*=}" && shift ;;
        --claim-set)
            [ $# -ge 2 ] || die "$STEP_ARGS" "--claim-set requires a value"
            CLAIM_SET_ARG="$2"
            shift 2
            ;;
        --claim-set=*) CLAIM_SET_ARG="${1#*=}" && shift ;;
        --edorg-ids)
            [ $# -ge 2 ] || die "$STEP_ARGS" "--edorg-ids requires a value"
            EDORG_IDS_ARG="$2"
            shift 2
            ;;
        --edorg-ids=*) EDORG_IDS_ARG="${1#*=}" && shift ;;
        --help | -h)
            usage
            exit 0
            ;;
        *) die "$STEP_ARGS" "unknown argument: $1 (see --help)" ;;
    esac
done

case "$SHAPE" in
    sis | assessment | warehouse) ;;
    "") die "$STEP_ARGS" "--shape is required: sis, assessment, or warehouse" ;;
    *) die "$STEP_ARGS" "--shape must be sis, assessment, or warehouse (got '$SHAPE')" ;;
esac

[ -n "$NAME" ] || die "$STEP_ARGS" "--name is required"
case "$NAME" in
    *[!A-Za-z0-9._-]*)
        die "$STEP_ARGS" \
            "--name may contain only letters, digits, '.', '_', and '-' (got '$NAME')"
        ;;
esac
NAME_LEN=${#NAME}
if [ "$NAME_LEN" -lt 1 ] || [ "$NAME_LEN" -gt 64 ]; then
    die "$STEP_ARGS" "--name must be 1-64 characters (got $NAME_LEN)"
fi

if [ -n "$EDORG_IDS_ARG" ]; then
    EDORG_IDS_JSON_ARG=$(printf '%s' "$EDORG_IDS_ARG" | jq -R -c '
        split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | map(select(length > 0) | tonumber)
    ' 2>/dev/null) || EDORG_IDS_JSON_ARG=""
    [ -n "$EDORG_IDS_JSON_ARG" ] && [ "$EDORG_IDS_JSON_ARG" != "[]" ] \
        || die "$STEP_ARGS" "--edorg-ids must be a comma-separated list of numbers (got '$EDORG_IDS_ARG')"
fi

require_env "$STEP_ARGS" \
    CMS_ADMIN_CLIENT_SECRET CONFIG_BASE_URL DMS_BASE_URL \
    INGRESS_BASE_URL INGRESS_CA_FILE PUBLIC_ORIGIN DMS_PATH_BASE \
    POSTGRES_PASSWORD POSTGRES_DB_NAME

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
RUNTIME_DIR="${RUNTIME_DIR:-/runtime}"
CRED_DIR="$RUNTIME_DIR/credentials"
CRED_FILE="$CRED_DIR/$NAME.json"

# A private scratch directory for request/response bodies. Removed on exit either way.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/new-credential.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------------------------
# Step b: is CMS even reachable? A clear, specific message here beats a token-request die further
# down for the "forgot to start the stack" case (FR-CRED-6).
# ------------------------------------------------------------------------------------------------

check_cms_ready() {
    if ! kit_curl --connect-timeout 3 --max-time 5 -o /dev/null \
        --request POST "${CONFIG_BASE_URL}/connect/token" >/dev/null 2>&1; then
        die "$STEP_READY" "CMS is not reachable: run ./start.sh (or start.ps1) first"
    fi
}

check_cms_ready

ADMIN_TOKEN=$(cms_token "$STEP_TOKEN" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" edfi_admin_api/full_access)

# ------------------------------------------------------------------------------------------------
# Step c: uniqueness (FR-CRED-3). Checked, and only checked, before anything is created: an existing
# application named $NAME, or an existing credentials file, both reject the run untouched.
# ------------------------------------------------------------------------------------------------

check_uniqueness() {
    _cu_ids=$(cms_find_application_ids_by_name "$STEP_UNIQUE" "$ADMIN_TOKEN" "$NAME")
    if [ -n "$_cu_ids" ]; then
        die "$STEP_UNIQUE" \
            "an application named '$NAME' already exists in CMS (id(s): $(printf '%s' "$_cu_ids" | tr '\n' ' ' | sed 's/ *$//')). Choose a different --name, or remove the existing application in CMS first."
    fi
    if [ -f "$CRED_FILE" ]; then
        die "$STEP_UNIQUE" \
            "$CRED_FILE already exists. Choose a different --name, or remove the file first."
    fi
}

check_uniqueness

# ------------------------------------------------------------------------------------------------
# Step d: which template is actually loaded? Read the kit.initialization marker (the same table
# init/template.sh writes); fall back to DATABASE_TEMPLATE if the marker is missing or the database
# isn't reachable, so this script degrades gracefully rather than failing outright.
# ------------------------------------------------------------------------------------------------

determine_template() {
    export PGHOST="${DB_HOST:-db}"
    export PGPORT="${DB_PORT:-5432}"
    export PGUSER=postgres
    export PGDATABASE="$POSTGRES_DB_NAME"
    export PGPASSWORD="$POSTGRES_PASSWORD"

    _dt_row=$(kit_psql -c \
        "SELECT template FROM kit.initialization ORDER BY completed_at DESC LIMIT 1;" \
        2>"$WORK_DIR/psql-err") || _dt_row=""

    if [ -n "$_dt_row" ]; then
        TEMPLATE="$_dt_row"
        log "$STEP_TEMPLATE" "template '$TEMPLATE' read from the kit.initialization marker"
    else
        TEMPLATE="${DATABASE_TEMPLATE:-minimal}"
        log "$STEP_TEMPLATE" \
            "no kit.initialization marker found; falling back to DATABASE_TEMPLATE='$TEMPLATE'"
    fi
}

determine_template

# ------------------------------------------------------------------------------------------------
# Step e: the claim set. Defaults from --shape, overridable with --claim-set; either way it must
# already exist in CMS (FR-CLAIM-10).
# ------------------------------------------------------------------------------------------------

case "$SHAPE" in
    sis) DEFAULT_CLAIM_SET=SISVendor ;;
    assessment) DEFAULT_CLAIM_SET=AssessmentVendor ;;
    warehouse) DEFAULT_CLAIM_SET=DataWarehouse ;;
esac
CLAIM_SET="${CLAIM_SET_ARG:-$DEFAULT_CLAIM_SET}"

validate_claim_set() {
    cms_request "$STEP_CLAIMSET" GET "${CONFIG_BASE_URL}/v3/claimSets?limit=500" "$ADMIN_TOKEN"
    if [ "$CMS_REQUEST_STATUS" != "200" ]; then
        die "$STEP_CLAIMSET" \
            "GET /v3/claimSets returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    _vcs_found=$(jq -r --arg n "$CLAIM_SET" 'map(select(.claimSetName == $n)) | length' \
        "$CMS_REQUEST_BODY_FILE")
    if [ "$_vcs_found" = "0" ]; then
        _vcs_valid=$(jq -r '[.[].claimSetName] | sort | join(", ")' "$CMS_REQUEST_BODY_FILE")
        rm -f "$CMS_REQUEST_BODY_FILE"
        die "$STEP_CLAIMSET" \
            "claim set '$CLAIM_SET' does not exist in CMS. Valid claim sets: $_vcs_valid"
    fi
    rm -f "$CMS_REQUEST_BODY_FILE"
    log "$STEP_CLAIMSET" "using claim set '$CLAIM_SET'"
}

validate_claim_set

# ------------------------------------------------------------------------------------------------
# Step f: education organization ids (FR-CRED-4/7/8/9/10). warehouse always defaults to none, since
# DataWarehouse reads with NoFurtherAuthorizationRequired and isn't scoped (decision 6, plan.md); an
# explicit --edorg-ids for a warehouse credential is accepted (harmless on the application record)
# but warned about, since it has no effect on what the credential can read.
# ------------------------------------------------------------------------------------------------

SEA_ID=""
if [ "$SHAPE" != "warehouse" ] && [ "$TEMPLATE" != "populated" ]; then
    BASELINE_FILE="$BOOTSTRAP_DIR/baseline-edorgs.json"
    [ -f "$BASELINE_FILE" ] || die "$STEP_EDORGS" "$BASELINE_FILE not found"
    SEA_ID=$(jq -r '[.[] | select(.resource == "stateEducationAgencies")]
        | if length > 0 then (.[0].naturalKey | to_entries[0].value) else empty end' "$BASELINE_FILE")
    [ -n "$SEA_ID" ] || die "$STEP_EDORGS" \
        "no stateEducationAgencies entry in $BASELINE_FILE to derive a default education organization id"
fi

if [ "$SHAPE" = "warehouse" ]; then
    DEFAULT_EDORG_IDS_JSON="[]"
    DEFAULT_EDORG_DESC="none: the DataWarehouse claim set reads without education organization scoping"
elif [ "$TEMPLATE" = "populated" ]; then
    DEFAULT_EDORG_IDS_JSON="[255901]"
    DEFAULT_EDORG_DESC="the sample LEA (255901) on the populated template"
else
    DEFAULT_EDORG_IDS_JSON="[$SEA_ID]"
    DEFAULT_EDORG_DESC="the bootstrapped SEA ($SEA_ID) on the minimal template"
fi

if [ -n "$EDORG_IDS_ARG" ]; then
    EDORG_IDS_JSON="$EDORG_IDS_JSON_ARG"
    if [ "$SHAPE" = "warehouse" ]; then
        log "$STEP_EDORGS" \
            "WARNING: --edorg-ids was given for a warehouse credential; DataWarehouse ignores" \
            "education organization scoping, so $EDORG_IDS_JSON will be recorded but has no effect" \
            "on what this credential can read."
    fi
    log "$STEP_EDORGS" "education organization ids: $EDORG_IDS_JSON (source: --edorg-ids)"
else
    EDORG_IDS_JSON="$DEFAULT_EDORG_IDS_JSON"
    log "$STEP_EDORGS" "education organization ids: $EDORG_IDS_JSON (default: $DEFAULT_EDORG_DESC)"
fi

# ------------------------------------------------------------------------------------------------
# Step g: one vendor per credential, named after --name (spike-notes Q7 parses its id from the
# Location header via cms_ensure_vendor). uri://gbisd.edu is added on the populated template so
# writes against the sample data's namespace succeed too.
# ------------------------------------------------------------------------------------------------

NAMESPACE_PREFIXES="uri://ed-fi.org"
if [ "$TEMPLATE" = "populated" ]; then
    NAMESPACE_PREFIXES="uri://ed-fi.org,uri://gbisd.edu"
fi

VENDOR_ID=$(cms_ensure_vendor "$STEP_VENDOR" "$ADMIN_TOKEN" "$NAME" \
    "Pilot Kit Automation" "pilot-kit@example.com" "$NAMESPACE_PREFIXES")
log "$STEP_VENDOR" "vendor '$NAME' id=$VENDOR_ID"

DATASTORE_ID=$(cms_find_datastore_id "$STEP_APP" "$ADMIN_TOKEN" "Pilot Kit")

APP_BODY=$(jq -n \
    --argjson vendorId "$VENDOR_ID" \
    --arg applicationName "$NAME" \
    --arg claimSetName "$CLAIM_SET" \
    --argjson dataStoreId "$DATASTORE_ID" \
    --argjson educationOrganizationIds "$EDORG_IDS_JSON" \
    '{vendorId: $vendorId, applicationName: $applicationName, claimSetName: $claimSetName,
      educationOrganizationIds: $educationOrganizationIds, dataStoreIds: [$dataStoreId]}')
cms_create_application "$STEP_APP" "$ADMIN_TOKEN" "$APP_BODY"
log "$STEP_APP" \
    "created application '$NAME' id=$CMS_APPLICATION_ID claimSetName=$CLAIM_SET" \
    "educationOrganizationIds=$EDORG_IDS_JSON (secret not logged)"

# ------------------------------------------------------------------------------------------------
# Step h: write /runtime/credentials/<name>.json before verifying anything, mode 600, atomically, and
# owned like init/bootstrap.sh writes bootstrap-credentials.json -- so the secret (shown only once by
# CMS) is captured even if the verification GET below fails.
# ------------------------------------------------------------------------------------------------

TOKEN_URL="${PUBLIC_ORIGIN}/${DMS_PATH_BASE}/oauth/token"
API_BASE_URL="${PUBLIC_ORIGIN}/${DMS_PATH_BASE}"

write_credentials_file() {
    _wcf_created_dir=false
    if [ ! -d "$CRED_DIR" ]; then
        mkdir -p "$CRED_DIR" || die "$STEP_WRITE" "could not create $CRED_DIR"
        _wcf_created_dir=true
    fi
    _wcf_owner=$(stat -c '%u:%g' "$RUNTIME_DIR") || die "$STEP_WRITE" "could not stat $RUNTIME_DIR"

    _wcf_created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _wcf_note="This secret cannot be recovered from CMS after creation; it was shown once, on stdout, \
when this credential was created. If it is lost, run new-credential again with a different --name."

    _wcf_tmp=$(mktemp "$CRED_DIR/.$NAME.XXXXXX") \
        || die "$STEP_WRITE" "could not create a temp file in $CRED_DIR"

    jq -n \
        --arg name "$NAME" \
        --arg shape "$SHAPE" \
        --arg claimSetName "$CLAIM_SET" \
        --arg key "$CMS_APPLICATION_KEY" \
        --arg secret "$CMS_APPLICATION_SECRET" \
        --argjson educationOrganizationIds "$EDORG_IDS_JSON" \
        --arg vendorName "$NAME" \
        --argjson applicationId "$CMS_APPLICATION_ID" \
        --arg tokenUrl "$TOKEN_URL" \
        --arg apiBaseUrl "$API_BASE_URL" \
        --arg createdAt "$_wcf_created_at" \
        --arg note "$_wcf_note" \
        '{name: $name, shape: $shape, claimSetName: $claimSetName, key: $key, secret: $secret,
          educationOrganizationIds: $educationOrganizationIds, vendorName: $vendorName,
          applicationId: $applicationId, tokenUrl: $tokenUrl, apiBaseUrl: $apiBaseUrl,
          createdAt: $createdAt, note: $note}' \
        >"$_wcf_tmp" || die "$STEP_WRITE" "could not write $_wcf_tmp"

    chmod 600 "$_wcf_tmp" || die "$STEP_WRITE" "could not chmod $_wcf_tmp"
    mv "$_wcf_tmp" "$CRED_FILE" || die "$STEP_WRITE" "could not move $_wcf_tmp to $CRED_FILE"
    chown "$_wcf_owner" "$CRED_FILE" \
        || log "$STEP_WRITE" "WARNING: could not chown $CRED_FILE to $_wcf_owner"
    if [ "$_wcf_created_dir" = true ]; then
        chown "$_wcf_owner" "$CRED_DIR" \
            || log "$STEP_WRITE" "WARNING: could not chown $CRED_DIR to $_wcf_owner"
    fi
    log "$STEP_WRITE" "wrote $CRED_FILE (mode 600, owner $_wcf_owner)"
}

write_credentials_file

# ------------------------------------------------------------------------------------------------
# Step i: verify the first authorized request succeeds with no extra configuration (FR-CRED-1),
# through the same NGINX ingress a participant uses (spike-notes Q7: no 401 window was observed, but
# a short retry with backoff stays cheap insurance). A failure here does not undo anything created
# above -- the credential and file are kept, and the failure is reported clearly.
# ------------------------------------------------------------------------------------------------

case "$SHAPE" in
    sis) VERIFY_PATH="/data/ed-fi/schools" ;;
    assessment) VERIFY_PATH="/data/ed-fi/assessments" ;;
    warehouse) VERIFY_PATH="/data/ed-fi/students?limit=1" ;;
esac
VERIFY_URL="${INGRESS_BASE_URL}/${DMS_PATH_BASE}${VERIFY_PATH}"

verify_first_request() {
    _vfr_token=$(dms_token "$STEP_VERIFY" "$DMS_BASE_URL" "$CMS_APPLICATION_KEY" "$CMS_APPLICATION_SECRET")

    _vfr_attempt=1
    _vfr_max=3
    _vfr_delay=1
    while :; do
        _vfr_body="$WORK_DIR/verify-response.json"
        if ! _vfr_status=$(kit_curl -o "$_vfr_body" -w '%{http_code}' \
            --cacert "$INGRESS_CA_FILE" \
            --request GET "$VERIFY_URL" \
            --header "Authorization: Bearer $_vfr_token"); then
            _vfr_status=000
        fi

        if [ "$_vfr_status" = "200" ]; then
            log "$STEP_VERIFY" "GET $VERIFY_URL -> 200 (attempt $_vfr_attempt of $_vfr_max)"
            return 0
        fi

        if [ "$_vfr_status" = "401" ] && [ "$_vfr_attempt" -lt "$_vfr_max" ]; then
            log "$STEP_VERIFY" \
                "GET $VERIFY_URL -> 401 (attempt $_vfr_attempt of $_vfr_max), retrying in ${_vfr_delay}s"
            sleep "$_vfr_delay"
            _vfr_delay=$((_vfr_delay * 2))
            _vfr_attempt=$((_vfr_attempt + 1))
            continue
        fi

        log "$STEP_VERIFY" \
            "WARNING: GET $VERIFY_URL returned HTTP $_vfr_status (expected 200) after $_vfr_attempt" \
            "attempt(s): $(cat "$_vfr_body" 2>/dev/null)"
        return 1
    done
}

VERIFY_OK=true
verify_first_request || VERIFY_OK=false

# ------------------------------------------------------------------------------------------------
# Step j: stdout. The key and secret are printed here, and only here, deliberately (FR-CRED-2).
# Everything above went to stderr through log()/die().
# ------------------------------------------------------------------------------------------------

printf -- '---------------------------------------------------------------\n'
printf 'Credential "%s" created (shape=%s, claimSet=%s)\n' "$NAME" "$SHAPE" "$CLAIM_SET"
printf 'Key:       %s\n' "$CMS_APPLICATION_KEY"
printf 'Secret:    %s\n' "$CMS_APPLICATION_SECRET"
printf 'Token URL: %s\n' "$TOKEN_URL"
printf 'Saved to:  ed-fi-api-v8/.runtime/credentials/%s.json\n' "$NAME"
printf 'WARNING: this secret cannot be recovered later -- store it now.\n'
if [ "$VERIFY_OK" != true ]; then
    printf 'WARNING: the first authorized request could not be verified; see the log output above.\n'
    printf '         The credential and its file were kept -- retry the request once the stack is up.\n'
    exit 1
fi
printf -- '---------------------------------------------------------------\n'
