# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Shared POSIX sh helpers for the one-shot init containers (Task 3's identity.sh, and Tasks 4/8-13).
# The tools image's /bin/sh is dash, so this file (and every script that sources it) stays inside
# POSIX sh: no arrays, no [[ ]], no here-strings, no ${var,,}. Source it, don't execute it:
#   . "$(dirname -- "$0")/lib.sh"

# log <step> <message...>
# Every line goes to stderr so a service's stdout stays free for values a caller might capture
# (init.sh scripts here don't do that today, but stderr-only logging costs nothing and avoids the
# trap later). <step> lets `docker compose logs init-identity` be greppable by phase (FR-BOOT-9).
log() {
    step="$1"
    shift
    printf '[%s] %s\n' "$step" "$*" >&2
}

# die <step> <message...>
# Logs like `log`, prefixed ERROR, then exits 1. Every init script's failure must name the step it
# failed in (FR-BOOT-9), so this is the only way scripts should abort.
die() {
    step="$1"
    shift
    printf '[%s] ERROR: %s\n' "$step" "$*" >&2
    exit 1
}

# require_env <step> <VAR_NAME> [VAR_NAME...]
# Fails via `die`, naming both the step and the missing variable, if any named variable is unset or
# empty. Compose already marks the truly required-for-every-run variables with `:?...`, so this is
# for variables a script needs but Compose can't usefully gate (for example, one of several secrets
# validated together so every problem is reported by name instead of stopping at the first).
require_env() {
    step="$1"
    shift
    for _require_env_name in "$@"; do
        eval "_require_env_value=\${${_require_env_name}:-}"
        if [ -z "$_require_env_value" ]; then
            die "$step" "$_require_env_name must be set"
        fi
    done
    unset _require_env_name _require_env_value
}

# cms_token <step> <client_id> <client_secret> <scope> -> the access_token on stdout.
# Requests a client-credentials token from CMS at CONFIG_BASE_URL/connect/token. Dies, naming
# <step>, on a request that can't be sent, a non-200 response, or a 200 with no access_token. The
# secret is a curl argument, so it's briefly visible in the container's process list; acceptable for
# a local kit (spike-notes Q2).
cms_token() {
    _ct_step="$1"
    _ct_client_id="$2"
    _ct_client_secret="$3"
    _ct_scope="$4"
    _ct_response_file=$(mktemp "${TMPDIR:-/tmp}/cms-token.XXXXXX")
    _ct_status=$(kit_curl -o "$_ct_response_file" -w '%{http_code}' \
        --request POST "${CONFIG_BASE_URL}/connect/token" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$_ct_client_id" \
        --data-urlencode "client_secret=$_ct_client_secret" \
        --data-urlencode "scope=$_ct_scope") || {
        rm -f "$_ct_response_file"
        die "$_ct_step" "the token request to $CONFIG_BASE_URL failed or timed out"
    }

    if [ "$_ct_status" != "200" ]; then
        rm -f "$_ct_response_file"
        die "$_ct_step" "token request for $_ct_client_id returned HTTP $_ct_status, expected 200"
    fi

    _ct_token=$(jq -r '.access_token // empty' "$_ct_response_file" 2>/dev/null)
    rm -f "$_ct_response_file"
    if [ -z "$_ct_token" ]; then
        die "$_ct_step" "token response for $_ct_client_id had no access_token"
    fi
    printf '%s' "$_ct_token"
}

# kit_curl [curl args...]
# curl with bounded timeouts, so an unanswered request fails the step instead of hanging `up`.
kit_curl() {
    curl -sS --connect-timeout 10 --max-time 60 "$@"
}

# kit_psql [psql args...]
# The one place that spells out the flags every psql call in this kit must use:
#   -v ON_ERROR_STOP=1  a failed statement stops the script instead of being silently skipped
#   -X                  ignore ~/.psqlrc; the container has none, but this keeps behavior host-independent
#   -q                  no "SET"/row-count chatter mixed into script output
#   -tA                  tuples-only, unaligned; a single-column SELECT prints just the value
# Connection parameters (PGHOST/PGUSER/PGDATABASE/PGPASSWORD) come from the caller's environment.
# Callers pass psql variables with -v name=value and reference them as :'name' in SQL text given
# through -f (a file or `-f -` with a heredoc): :'name' interpolation is not available inside -c.
kit_psql() {
    psql -v ON_ERROR_STOP=1 -X -q -tA "$@"
}

# dms_token <step> <dms_base_url> <key> <secret> -> the access_token on stdout.
# Requests a client-credentials token directly from DMS (DMS proxies to CMS's /connect/token --
# spike-notes Q7), using HTTP Basic auth with an application's key and secret -- how BulkLoadClient
# and every provisioned participant credential authenticate, unlike cms_token above (which POSTs
# client_id/client_secret to CMS directly, for the kit's own CMS system clients). Dies, naming
# <step>, on a request that can't be sent, a non-200 response, or a 200 with no access_token.
dms_token() {
    _dtk_step="$1"
    _dtk_base_url="$2"
    _dtk_key="$3"
    _dtk_secret="$4"
    _dtk_response_file=$(mktemp "${TMPDIR:-/tmp}/dms-token.XXXXXX")
    _dtk_status=$(kit_curl -o "$_dtk_response_file" -w '%{http_code}' \
        --request POST "${_dtk_base_url}/oauth/token" \
        --user "${_dtk_key}:${_dtk_secret}" \
        --data-urlencode "grant_type=client_credentials") || {
        rm -f "$_dtk_response_file"
        die "$_dtk_step" "the token request to $_dtk_base_url/oauth/token failed or timed out"
    }
    if [ "$_dtk_status" != "200" ]; then
        rm -f "$_dtk_response_file"
        die "$_dtk_step" \
            "token request to $_dtk_base_url/oauth/token returned HTTP $_dtk_status, expected 200"
    fi
    _dtk_token=$(jq -r '.access_token // empty' "$_dtk_response_file" 2>/dev/null)
    rm -f "$_dtk_response_file"
    [ -n "$_dtk_token" ] \
        || die "$_dtk_step" "token response from $_dtk_base_url/oauth/token had no access_token"
    printf '%s' "$_dtk_token"
}

# cms_request <step> <method> <url> <token> [curl-data-args...]
# Issues one bearer-authenticated CMS request. Only a request that can't be sent or times out dies
# here (naming <step>); the caller decides which status codes are acceptable, since that differs by
# call (create-if-absent, a 200-or-201 upsert, a DELETE whose failure is only ever a warning). Sets
# three globals for the caller to read before the next cms_* call overwrites them:
#   CMS_REQUEST_STATUS       the HTTP status code
#   CMS_REQUEST_BODY_FILE    path to a fresh temp file holding the response body
#   CMS_REQUEST_LOCATION     the Location header value, or empty if none was sent
# The body file is never removed here -- callers that don't need it must rm it themselves.
cms_request() {
    _crq_step="$1"
    _crq_method="$2"
    _crq_url="$3"
    _crq_token="$4"
    shift 4
    CMS_REQUEST_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/cms-request.XXXXXX")
    _crq_headers_file=$(mktemp "${TMPDIR:-/tmp}/cms-headers.XXXXXX")
    CMS_REQUEST_STATUS=$(kit_curl -o "$CMS_REQUEST_BODY_FILE" -D "$_crq_headers_file" -w '%{http_code}' \
        --request "$_crq_method" "$_crq_url" \
        --header "Authorization: Bearer $_crq_token" "$@") || {
        rm -f "$_crq_headers_file"
        die "$_crq_step" "$_crq_method $_crq_url failed or timed out"
    }
    CMS_REQUEST_LOCATION=$(tr -d '\r' <"$_crq_headers_file" \
        | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -n1)
    rm -f "$_crq_headers_file"
}

# cms_ensure_vendor <step> <token> <company> <contact_name> <contact_email> <namespace_prefixes>
# Finds a vendor by company name (GET-then-match: CMS has no upsert for this resource), or creates
# one and parses its id from the Location header (POST /v3/vendors returns 201 with an empty body --
# spike-notes Q7). Prints the vendor id on stdout.
cms_ensure_vendor() {
    _cev_step="$1"
    _cev_token="$2"
    _cev_company="$3"
    _cev_contact_name="$4"
    _cev_contact_email="$5"
    _cev_namespace_prefixes="$6"

    cms_request "$_cev_step" GET "${CONFIG_BASE_URL}/v3/vendors" "$_cev_token"
    if [ "$CMS_REQUEST_STATUS" != "200" ]; then
        die "$_cev_step" "GET /v3/vendors returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    _cev_id=$(jq -r --arg company "$_cev_company" \
        'map(select(.company == $company)) | .[0].id // empty' "$CMS_REQUEST_BODY_FILE")
    rm -f "$CMS_REQUEST_BODY_FILE"
    if [ -n "$_cev_id" ]; then
        printf '%s' "$_cev_id"
        return 0
    fi

    _cev_body=$(jq -n \
        --arg company "$_cev_company" \
        --arg contactName "$_cev_contact_name" \
        --arg contactEmailAddress "$_cev_contact_email" \
        --arg namespacePrefixes "$_cev_namespace_prefixes" \
        '{company: $company, contactName: $contactName, contactEmailAddress: $contactEmailAddress,
          namespacePrefixes: $namespacePrefixes}')
    cms_request "$_cev_step" POST "${CONFIG_BASE_URL}/v3/vendors" "$_cev_token" \
        --header "Content-Type: application/json" --data "$_cev_body"
    if [ "$CMS_REQUEST_STATUS" != "201" ]; then
        die "$_cev_step" "POST /v3/vendors returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    rm -f "$CMS_REQUEST_BODY_FILE"
    [ -n "$CMS_REQUEST_LOCATION" ] || die "$_cev_step" "POST /v3/vendors returned 201 with no Location header"
    _cev_id=${CMS_REQUEST_LOCATION##*/}
    [ -n "$_cev_id" ] || die "$_cev_step" "could not parse a vendor id from Location: $CMS_REQUEST_LOCATION"
    printf '%s' "$_cev_id"
}

# cms_find_datastore_id <step> <token> <name> -> the data store id on stdout. Dies if none is
# registered under that name -- callers of this run after init-datastore, so an absent data store
# means something else is already broken.
cms_find_datastore_id() {
    _cfd_step="$1"
    _cfd_token="$2"
    _cfd_name="$3"
    cms_request "$_cfd_step" GET "${CONFIG_BASE_URL}/v3/dataStores" "$_cfd_token"
    if [ "$CMS_REQUEST_STATUS" != "200" ]; then
        die "$_cfd_step" \
            "GET /v3/dataStores returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    _cfd_id=$(jq -r --arg name "$_cfd_name" 'map(select(.name == $name)) | .[0].id // empty' \
        "$CMS_REQUEST_BODY_FILE")
    rm -f "$CMS_REQUEST_BODY_FILE"
    [ -n "$_cfd_id" ] || die "$_cfd_step" "no data store named '$_cfd_name' found in GET /v3/dataStores"
    printf '%s' "$_cfd_id"
}

# cms_create_application <step> <token> <body-json>
# POSTs a full application body (vendorId, applicationName, claimSetName,
# educationOrganizationIds, dataStoreIds, and so on -- this stays agnostic of the shape so Tasks 10
# and 13 can reuse it for other claim sets). On success, sets CMS_APPLICATION_ID, CMS_APPLICATION_KEY
# and CMS_APPLICATION_SECRET from the 201 response body -- the only place the secret is ever returned
# (spike-notes Q7). Dies naming <step> on any other status, or on a 201 missing any of the three.
cms_create_application() {
    _cca_step="$1"
    _cca_token="$2"
    _cca_body="$3"
    cms_request "$_cca_step" POST "${CONFIG_BASE_URL}/v3/applications" "$_cca_token" \
        --header "Content-Type: application/json" --data "$_cca_body"
    if [ "$CMS_REQUEST_STATUS" != "201" ]; then
        die "$_cca_step" \
            "POST /v3/applications returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    CMS_APPLICATION_ID=$(jq -r '.id // empty' "$CMS_REQUEST_BODY_FILE")
    CMS_APPLICATION_KEY=$(jq -r '.key // empty' "$CMS_REQUEST_BODY_FILE")
    CMS_APPLICATION_SECRET=$(jq -r '.secret // empty' "$CMS_REQUEST_BODY_FILE")
    rm -f "$CMS_REQUEST_BODY_FILE"
    if [ -z "$CMS_APPLICATION_ID" ] || [ -z "$CMS_APPLICATION_KEY" ] || [ -z "$CMS_APPLICATION_SECRET" ]; then
        die "$_cca_step" "POST /v3/applications returned 201 but was missing id, key, or secret"
    fi
}

# cms_find_application_ids_by_name <step> <token> <application_name> -> one id per line on stdout
# (nothing if none match). Used to find and remove leftover kit applications left behind by an
# earlier failed or interrupted run, matched by name rather than trusting a saved id.
cms_find_application_ids_by_name() {
    _cfa_step="$1"
    _cfa_token="$2"
    _cfa_name="$3"
    cms_request "$_cfa_step" GET "${CONFIG_BASE_URL}/v3/applications" "$_cfa_token"
    if [ "$CMS_REQUEST_STATUS" != "200" ]; then
        die "$_cfa_step" \
            "GET /v3/applications returned HTTP $CMS_REQUEST_STATUS: $(cat "$CMS_REQUEST_BODY_FILE")"
    fi
    jq -r --arg name "$_cfa_name" '.[] | select(.applicationName == $name) | .id' "$CMS_REQUEST_BODY_FILE"
    rm -f "$CMS_REQUEST_BODY_FILE"
}

# cms_delete_application <step> <token> <id> -> the HTTP status code on stdout.
# DELETE /v3/applications/{id} is not proven against real CMS as of Task 8 (the spike didn't cover
# it). This only sends the request and reports the status -- it never dies, so callers can choose to
# warn (a credential that should have been deleted, but wasn't, isn't a load failure) or fail,
# depending on context.
cms_delete_application() {
    _cda_step="$1"
    _cda_token="$2"
    _cda_id="$3"
    cms_request "$_cda_step" DELETE "${CONFIG_BASE_URL}/v3/applications/${_cda_id}" "$_cda_token"
    rm -f "$CMS_REQUEST_BODY_FILE"
    printf '%s' "$CMS_REQUEST_STATUS"
}
