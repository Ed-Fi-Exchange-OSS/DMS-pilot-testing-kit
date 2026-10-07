#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Maintainer runbook for Checkpoint E: runs the "Host check before distribution" table in
# tasks/traceability.md against a running kit on a Docker host. Not a participant tool, and not
# part of CI. Each check prints PASS/FAIL with the evidence, and the run ends with a summary.
#
# Checks that edit .env back it up to .env.host-checks.bak first and restore it afterwards, including
# on Ctrl+C. Throwaway credentials, a claim set, a vendor, and a Profile are left in CMS; `reset`
# clears them. `bad-checksum` RESETS the stack (all data is lost) and leaves it on the populated
# template.

# shellcheck disable=SC2015  # `test && pass ... || fail ...` is safe: pass and note always return 0
set -uo pipefail
export MSYS_NO_PATHCONV=1

KIT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../ed-fi-api-v8" && pwd)"
cd "$KIT_DIR" || exit 2

ENV_BACKUP=.env.host-checks.bak
RUN_ID=$(date +%s)
PASSES=()
FAILS=()

usage() {
    cat <<'EOF'
Usage: tasks/host-checks.sh <check>... | all | list

Runs Checkpoint E host checks from tasks/traceability.md against the running kit. Start the kit
first (./start.sh). Run `list` to see the checks; `all` runs every scripted check in a safe order,
ending with the destructive one (bad-checksum resets the stack).

Two checks stay manual and are printed at the end of `all`: pgAdmin in a browser, and a fresh
reader following the README (FR-DOC-7).
EOF
}

# --- helpers ------------------------------------------------------------------------------------

say() { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
pass() { PASSES+=("$1"); printf 'PASS  %s: %s\n' "$1" "$2"; }
fail() { FAILS+=("$1"); printf 'FAIL  %s: %s\n' "$1" "$2"; }

env_get() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2-; }

# Replaces VAR's value in .env (or appends it). awk reads the value from the environment, so no
# character in it needs escaping.
env_set() {
    local tmp
    tmp=$(mktemp .env.XXXXXX)
    K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }' .env >"$tmp" && mv "$tmp" .env
}

env_backup() { cp -p .env "$ENV_BACKUP"; }
env_restore() { [ -f "$ENV_BACKUP" ] && mv -f "$ENV_BACKUP" .env; }
trap 'if [ -f "$ENV_BACKUP" ]; then env_restore; echo "(.env restored from $ENV_BACKUP)"; fi' EXIT
trap 'exit 130' INT TERM

ORIGIN=$(env_get PUBLIC_ORIGIN)
ORIGIN=${ORIGIN:-https://localhost}
HTTP_PORT=$(env_get HTTP_PORT)
HTTP_PORT=${HTTP_PORT:-80}

code() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }

DB_NAME=$(env_get POSTGRES_DB_NAME)
DB_NAME=${DB_NAME:-edfi_datamanagementservice}

# CMS and DMS share one database.
psql_q() { docker compose exec -T db psql -U postgres -d "$DB_NAME" -X -tAc "$1"; }

template_in_use() { psql_q 'SELECT template FROM kit.initialization ORDER BY completed_at DESC LIMIT 1' 2>/dev/null | tr -d '[:space:]'; }

# Restarts whatever needs restarting and waits until healthy. Returns start.sh's exit code.
restart_kit() { ./start.sh >/dev/null 2>&1; }

dms_token() { # <key> <secret>
    curl -sk -u "$1:$2" -d grant_type=client_credentials "$ORIGIN/api/oauth/token" | jq -r '.access_token // empty'
}
boot_token() { dms_token "$(jq -r .key .runtime/bootstrap-credentials.json)" "$(jq -r .secret .runtime/bootstrap-credentials.json)"; }
cred_token() { dms_token "$(jq -r .key ".runtime/credentials/$1.json")" "$(jq -r .secret ".runtime/credentials/$1.json")"; }

cms_token_status() { # <secret> -> HTTP status of a PilotKitAdmin token request
    curl -sk -o /dev/null -w '%{http_code}' "$ORIGIN/config/connect/token" \
        --data-urlencode grant_type=client_credentials --data-urlencode client_id=PilotKitAdmin \
        --data-urlencode "client_secret=$1" --data-urlencode scope=edfi_admin_api/full_access
}
admin_token() {
    curl -sk "$ORIGIN/config/connect/token" \
        --data-urlencode grant_type=client_credentials --data-urlencode client_id=PilotKitAdmin \
        --data-urlencode "client_secret=$(env_get CMS_ADMIN_CLIENT_SECRET)" \
        --data-urlencode scope=edfi_admin_api/full_access | jq -r '.access_token // empty'
}

# 32+ characters with every class the identity init requires; no characters that need quoting.
new_secret() { printf 'Hc%sa1Z!' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')"; }

# --- checks -------------------------------------------------------------------------------------

check_discovery_https() { # T5: Discovery URLs use the public origin (FR-ROUTE-4)
    say "discovery-https"
    local urls bad
    urls=$(curl -sk "$ORIGIN/api" | jq -r '.urls | .. | strings' 2>/dev/null)
    bad=$(printf '%s\n' "$urls" | grep -v "^$ORIGIN/" || true)
    printf '%s\n' "$urls" | sed 's/^/    /'
    if [ -n "$urls" ] && [ -z "$bad" ]; then
        pass discovery-https "every Discovery URL starts with $ORIGIN/"
    else
        fail discovery-https "URLs not under $ORIGIN/: ${bad:-<no urls returned>}"
    fi
}

check_redirect_503() { # T5: http -> 301 https; DMS stopped -> 503 not 502 (FR-ROUTE-9)
    say "redirect-503"
    local r s
    # Status and Location from the raw headers; curl's %{redirect_url} came back empty on one host.
    r=$(curl -s -o /dev/null -D - "http://localhost:$HTTP_PORT/api" | tr -d '\r' \
        | awk 'NR == 1 { code = $2 } tolower($1) == "location:" { loc = $2 } END { print code, loc }')
    note "http://localhost:$HTTP_PORT/api -> $r"
    case "$r" in 301\ https://*) pass redirect-301 "$r" ;; *) fail redirect-301 "expected 301 to https://, got '$r'" ;; esac
    docker compose stop dms >/dev/null 2>&1
    s=$(code "$ORIGIN/api")
    note "with dms stopped: $ORIGIN/api -> $s"
    [ "$s" = 503 ] && pass dms-down-503 "503 with DMS stopped" || fail dms-down-503 "expected 503, got $s"
    restart_kit && note "kit restarted" || fail redirect-503 "./start.sh failed while restoring DMS"
}

check_secrets_in_logs() { # T3: no .env secret appears in any container log
    say "secrets-in-logs"
    local logs v s leaks=""
    logs=$(docker compose logs --no-color 2>&1)
    for v in POSTGRES_PASSWORD CMS_SERVICE_CLIENT_SECRET CMS_READONLY_CLIENT_SECRET CMS_ADMIN_CLIENT_SECRET \
        CMS_DATABASE_ENCRYPTION_KEY CMS_IDENTITY_ENCRYPTION_KEY PGADMIN_DEFAULT_PASSWORD; do
        s=$(env_get "$v")
        [ -n "$s" ] || continue
        if printf '%s' "$logs" | grep -qF -- "$s"; then leaks="$leaks $v"; fi
    done
    [ -z "$leaks" ] && pass secrets-in-logs "no .env secret found in docker compose logs" \
        || fail secrets-in-logs "found in logs:$leaks"
}

check_counts_stable() { # T3: a second start makes no new key or client rows
    say "counts-stable"
    local q before after
    q='SELECT (SELECT count(*) FROM dmscs."OpenIddictKey"), (SELECT count(*) FROM dmscs."OpenIddictApplication")'
    before=$(psql_q "$q")
    restart_kit || fail counts-stable "./start.sh failed"
    after=$(psql_q "$q")
    note "keys|clients before: $before   after: $after"
    [ -n "$before" ] && [ "$before" = "$after" ] && pass counts-stable "keys|clients $after, unchanged" \
        || fail counts-stable "before '$before', after '$after'"
}

check_missing_cert() { # T5: missing TLS key -> actionable NGINX error
    say "missing-cert"
    local logs
    mv ssl/server.key ssl/server.key.host-checks
    docker compose up -d --no-deps --force-recreate nginx >/dev/null 2>&1
    sleep 3 # give the entrypoint a moment to fail; the result is read from its log
    logs=$(docker compose logs --no-color --tail=20 nginx 2>&1)
    mv ssl/server.key.host-checks ssl/server.key
    printf '%s\n' "$logs" | grep -i "server.key" | sed 's/^/    /'
    if printf '%s' "$logs" | grep -q "server.key not found" && printf '%s' "$logs" | grep -q "generate-certificate"; then
        pass missing-cert "NGINX names the missing file and the certificate script"
    else
        fail missing-cert "no actionable message in the nginx log"
    fi
    docker compose up -d --no-deps --force-recreate nginx >/dev/null 2>&1
    restart_kit || fail missing-cert "./start.sh failed after restoring the key"
}

check_data_v3() { # T6: /data/v3 rewrite matches /api/data when on; 404 when off (FR-ROUTE-6)
    say "data-v3"
    local t s
    t=$(boot_token)
    if diff <(curl -sk -H "Authorization: Bearer $t" "$ORIGIN/data/v3/ed-fi/schools") \
            <(curl -sk -H "Authorization: Bearer $t" "$ORIGIN/api/data/ed-fi/schools") >/dev/null; then
        pass data-v3-on "same body as /api/data/ed-fi/schools"
    else
        fail data-v3-on "bodies differ"
    fi
    env_backup
    env_set DATA_V3_REWRITE_ENABLED false
    docker compose up -d --no-deps --wait nginx >/dev/null 2>&1
    s=$(code -H "Authorization: Bearer $t" "$ORIGIN/data/v3/ed-fi/schools")
    [ "$s" = 404 ] && pass data-v3-off "404 when DATA_V3_REWRITE_ENABLED=false" || fail data-v3-off "expected 404, got $s"
    env_restore
    docker compose up -d --no-deps --wait nginx >/dev/null 2>&1
}

check_rate_limit() { # T6: low rate -> 429s; default -> none (FR-ROUTE-8)
    say "rate-limit"
    local counts
    counts=$(for _ in $(seq 20); do code "$ORIGIN/api"; echo; done | sort | uniq -c | tr '\n' ' ')
    note "default config, 20 requests: $counts"
    case "$counts" in *429*) fail rate-limit-default "429s with the default config" ;; *) pass rate-limit-default "no 429s" ;; esac
    env_backup
    env_set RATE_LIMIT_ENABLED true
    env_set RATE_LIMIT_RATE 1r/s
    env_set RATE_LIMIT_BURST 0
    docker compose up -d --no-deps --wait nginx >/dev/null 2>&1
    counts=$(for _ in $(seq 20); do code "$ORIGIN/api"; echo; done | sort | uniq -c | tr '\n' ' ')
    note "1r/s, burst 0, 20 requests: $counts"
    case "$counts" in *429*) pass rate-limit-on "429s returned" ;; *) fail rate-limit-on "no 429s" ;; esac
    env_restore
    docker compose up -d --no-deps --wait nginx >/dev/null 2>&1
}

check_claimsets() { # T11: DataWarehouse listed; only Read and ReadChanges
    say "claimsets"
    local a actions
    a=$(admin_token)
    if curl -sk -H "Authorization: Bearer $a" "$ORIGIN/config/v3/claimSets?limit=500" | jq -e 'map(.claimSetName // .name) | index("DataWarehouse")' >/dev/null; then
        pass claimset-listed "DataWarehouse is in GET /config/v3/claimSets"
    else
        fail claimset-listed "DataWarehouse not found"
    fi
    actions=$(curl -sk -H "Authorization: Bearer $a" "$ORIGIN/config/v3/authorizationMetadata?claimSetName=DataWarehouse" \
        | jq -r '[.. | strings | select(test("^(Create|Read|Update|Delete|ReadChanges)$"))] | unique | join(",")')
    note "actions in DataWarehouse's authorization metadata: ${actions:-<none>}"
    [ "$actions" = "Read,ReadChanges" ] && pass claimset-actions "only Read and ReadChanges" \
        || fail claimset-actions "got '$actions'"
}

check_unknown_claimset() { # FR-CLAIM-10 / FR-CRED-10: unknown claim set rejected; edorg override works
    say "unknown-claimset"
    local out rc ed
    out=$(./new-credential.sh --shape sis --name "hc-bad-$RUN_ID" --claim-set NoSuchSet 2>&1); rc=$?
    printf '%s\n' "$out" | tail -n 4 | sed 's/^/    /'
    [ "$rc" -ne 0 ] && pass unknown-claimset "rejected (exit $rc)" || fail unknown-claimset "accepted NoSuchSet"
    [ "$(template_in_use)" = populated ] && ed=255901 || ed=990002
    ./new-credential.sh --shape sis --name "hc-edorg-$RUN_ID" --edorg-ids "$ed" >/dev/null 2>&1 \
        && pass edorg-override "--edorg-ids $ed accepted and first request succeeded" \
        || fail edorg-override "--edorg-ids $ed failed"
}

check_claimset_reload() { # T18: claim set imported on a running stack is usable at once
    say "claimset-reload"
    local dir=".runtime/hc-claimsets" name="HcReload$RUN_ID" out
    mkdir -p "$dir"
    jq --arg n "$name" '.claimSetName = $n' bootstrap/claimsets/DataWarehouse.json >"$dir/$name.json"
    out=$(docker compose run --rm --no-deps -e CLAIMSETS_DIR=/hc-claimsets \
        -v "$KIT_DIR/$dir:/hc-claimsets:ro" init-claimsets 2>&1)
    rm -rf "$dir"
    printf '%s\n' "$out" | grep -i "reload" | sed 's/^/    /'
    printf '%s' "$out" | grep -q "reloaded; usable immediately" \
        && pass claimset-reloaded "init-claimsets imported and reloaded $name" \
        || fail claimset-reloaded "no reload message from init-claimsets"
    ./new-credential.sh --shape warehouse --name "hc-reload-$RUN_ID" --claim-set "$name" >/dev/null 2>&1 \
        && pass claimset-usable "a credential with $name made its first request (200)" \
        || fail claimset-usable "new-credential with $name failed (a 500 here means the reload didn't apply)"
}

check_profiles() { # Checkpoint B / FR-FEAT-5: a Profile restricts the response
    say "profiles"
    local a pname vid did pid ed app key secret t body keys
    a=$(admin_token)
    pname="hc-school-names-$RUN_ID"
    pid=$(curl -sk -D - -o /dev/null -X POST "$ORIGIN/config/v3/profiles" -H "Authorization: Bearer $a" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$pname\",\"definition\":\"<Profile name=\\\"$pname\\\"><Resource name=\\\"School\\\"><ReadContentType memberSelection=\\\"IncludeOnly\\\"><Property name=\\\"nameOfInstitution\\\"/></ReadContentType></Resource></Profile>\"}" \
        | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/\([0-9][0-9]*\)$#\1#p')
    vid=$(curl -sk -D - -o /dev/null -X POST "$ORIGIN/config/v3/vendors" -H "Authorization: Bearer $a" \
        -H 'Content-Type: application/json' \
        -d "{\"company\":\"hc-profile-$RUN_ID\",\"contactName\":\"Host checks\",\"contactEmailAddress\":\"host-checks@example.com\",\"namespacePrefixes\":\"uri://ed-fi.org\"}" \
        | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/\([0-9][0-9]*\)$#\1#p')
    did=$(curl -sk -H "Authorization: Bearer $a" "$ORIGIN/config/v3/dataStores" | jq -r 'map(select(.name == "Pilot Kit")) | .[0].id // empty')
    note "profile id=${pid:-?} vendor id=${vid:-?} data store id=${did:-?}"
    if [ -z "$pid" ] || [ -z "$vid" ] || [ -z "$did" ]; then fail profiles "could not create the profile, vendor, or find the data store"; return; fi
    [ "$(template_in_use)" = populated ] && ed=255901 || ed=99
    app=$(curl -sk -X POST "$ORIGIN/config/v3/applications" -H "Authorization: Bearer $a" -H 'Content-Type: application/json' \
        -d "{\"vendorId\":$vid,\"applicationName\":\"hc-profile-$RUN_ID\",\"claimSetName\":\"EdFiSandbox\",\"educationOrganizationIds\":[$ed],\"dataStoreIds\":[$did],\"profileIds\":[$pid]}")
    key=$(printf '%s' "$app" | jq -r '.key // empty'); secret=$(printf '%s' "$app" | jq -r '.secret // empty')
    [ -n "$key" ] || { fail profiles "application create failed: $app"; return; }
    note "restarting dms (a Profile created while DMS runs isn't used until it restarts)"
    docker compose restart dms >/dev/null 2>&1 && restart_kit
    t=$(dms_token "$key" "$secret")
    body=$(curl -sk -H "Authorization: Bearer $t" -H "Accept: application/vnd.ed-fi.school.$pname.readable+json" \
        "$ORIGIN/api/data/ed-fi/schools?limit=1")
    keys=$(printf '%s' "$body" | jq -r '.[0] | keys | join(",")' 2>/dev/null)
    note "fields returned: ${keys:-$body}"
    if printf '%s' "$keys" | grep -q nameOfInstitution && \
        ! printf '%s' "$keys" | tr ',' '\n' | grep -qvE '^(nameOfInstitution|schoolId|id|_etag|_lastModifiedDate)$'; then
        pass profiles "response limited to the Profile's fields"
    else
        fail profiles "unexpected response"
    fi
}

check_bad_secret() { # T3/T4/FR-LIFE-9: invalid secret fails init-identity; the report names it
    say "bad-secret"
    local out rc
    env_backup
    env_set CMS_ADMIN_CLIENT_SECRET short
    out=$(./start.sh 2>&1); rc=$?
    env_restore
    printf '%s\n' "$out" | grep -E "FAILED|CMS_ADMIN_CLIENT_SECRET|docker compose logs" | head -n 6 | sed 's/^/    /'
    [ "$rc" -ne 0 ] && pass bad-secret-exit "start exited $rc" || fail bad-secret-exit "start exited 0"
    printf '%s' "$out" | grep -q "FAILED: init-identity" && pass bad-secret-service "report names init-identity" \
        || fail bad-secret-service "report doesn't name init-identity"
    printf '%s' "$out" | grep -q "CMS_ADMIN_CLIENT_SECRET must be" && pass bad-secret-variable "message names CMS_ADMIN_CLIENT_SECRET" \
        || fail bad-secret-variable "message doesn't name the variable"
    restart_kit && note "restored; kit healthy" || fail bad-secret "./start.sh failed after restoring .env"
}

check_secret_rotation() { # T3: changing a client secret in .env rotates only that client
    say "secret-rotation"
    local old new ro_before ro_after
    old=$(env_get CMS_ADMIN_CLIENT_SECRET)
    new=$(new_secret)
    ro_before=$(psql_q "SELECT \"ClientSecret\" FROM dmscs.\"OpenIddictApplication\" WHERE \"ClientId\" = 'CMSReadOnlyAccess'" | md5sum)
    env_backup
    env_set CMS_ADMIN_CLIENT_SECRET "$new"
    restart_kit || fail secret-rotation "./start.sh failed with the new secret"
    note "old secret -> $(cms_token_status "$old"), new secret -> $(cms_token_status "$new")"
    [ "$(cms_token_status "$new")" = 200 ] && pass rotation-new-works "new secret gets a token" || fail rotation-new-works "new secret rejected"
    [ "$(cms_token_status "$old")" != 200 ] && pass rotation-old-fails "old secret rejected" || fail rotation-old-fails "old secret still works"
    ro_after=$(psql_q "SELECT \"ClientSecret\" FROM dmscs.\"OpenIddictApplication\" WHERE \"ClientId\" = 'CMSReadOnlyAccess'" | md5sum)
    [ "$ro_before" = "$ro_after" ] && pass rotation-others-unchanged "CMSReadOnlyAccess untouched" \
        || fail rotation-others-unchanged "CMSReadOnlyAccess hash changed"
    env_restore
    restart_kit && [ "$(cms_token_status "$old")" = 200 ] && note "rotated back to the original secret" \
        || fail secret-rotation "could not rotate back; check CMS_ADMIN_CLIENT_SECRET in .env"
}

check_bad_checksum() { # T8/T9: corrupted archive fails clearly; no marker; next start retries. RESETS.
    say "bad-checksum (resets the stack)"
    local out rc marker
    ./reset.sh --force >/dev/null 2>&1 || { fail bad-checksum "reset failed"; return; }
    env_backup
    env_set DATA_STANDARD_SAMPLES_SHA256 0000000000000000000000000000000000000000000000000000000000000000
    out=$(./start.sh --template populated 2>&1); rc=$?
    printf '%s\n' "$out" | grep -E "FAILED|DATA_STANDARD_SAMPLES_SHA256" | head -n 4 | sed 's/^/    /'
    [ "$rc" -ne 0 ] && pass checksum-exit "start exited $rc" || fail checksum-exit "start exited 0"
    printf '%s' "$out" | grep -q "FAILED: init-template" && printf '%s' "$out" | grep -q DATA_STANDARD_SAMPLES_SHA256 \
        && pass checksum-message "names init-template and DATA_STANDARD_SAMPLES_SHA256" \
        || fail checksum-message "message doesn't name the service and the variable"
    marker=$(psql_q 'SELECT count(*) FROM kit.initialization' 2>/dev/null | tr -d '[:space:]')
    [ "${marker:-0}" = 0 ] && pass checksum-no-marker "no marker row" || fail checksum-no-marker "marker rows: $marker"
    env_restore
    out=$(./start.sh --template populated 2>&1); rc=$?
    marker=$(psql_q 'SELECT count(*) FROM kit.initialization' 2>/dev/null | tr -d '[:space:]')
    [ "$rc" = 0 ] && [ "$marker" = 1 ] && pass checksum-retry "next start loaded populated (marker row present)" \
        || fail checksum-retry "retry exit $rc, marker rows ${marker:-?}"
}

check_warehouse() { # T9/T11: warehouse reads everything incl. /deletes; writes 403 (populated only)
    say "warehouse"
    if [ "$(template_in_use)" != populated ]; then
        fail warehouse "needs the populated template (run bad-checksum first, or ./reset.sh --force --start with --template populated)"
        return
    fi
    local name="hc-wh-$RUN_ID" w total school sid s
    ./new-credential.sh --shape warehouse --name "$name" >/dev/null 2>&1 || { fail warehouse "new-credential failed"; return; }
    w=$(cred_token "$name")
    total=$(curl -sk -D - -o /dev/null -H "Authorization: Bearer $w" "$ORIGIN/api/data/ed-fi/students?limit=1&totalCount=true" \
        | tr -d '\r' | sed -n 's/^[Tt]otal-[Cc]ount: //p')
    [ "${total:-0}" -gt 0 ] && pass warehouse-students "Total-Count=$total (record it in the docs if it matters)" \
        || fail warehouse-students "no students visible"
    s=$(code -H "Authorization: Bearer $w" "$ORIGIN/api/data/ed-fi/students/deletes")
    [ "$s" = 200 ] && pass warehouse-deletes "students/deletes -> 200" || fail warehouse-deletes "students/deletes -> $s"
    school=$(curl -sk -H "Authorization: Bearer $w" "$ORIGIN/api/data/ed-fi/schools?limit=1" | jq -c '.[0]')
    sid=$(printf '%s' "$school" | jq -r .id)
    s=$(code -X POST -H "Authorization: Bearer $w" -H 'Content-Type: application/json' \
        -d "$(printf '%s' "$school" | jq -c 'del(.id, ._etag, ._lastModifiedDate)')" "$ORIGIN/api/data/ed-fi/schools")
    [ "$s" = 403 ] && pass warehouse-post-403 "POST an existing school -> 403" || fail warehouse-post-403 "POST -> $s"
    s=$(code -X DELETE -H "Authorization: Bearer $w" "$ORIGIN/api/data/ed-fi/schools/$sid")
    [ "$s" = 403 ] && pass warehouse-delete-403 "DELETE -> 403" || fail warehouse-delete-403 "DELETE -> $s"
}

# --- main ---------------------------------------------------------------------------------------

ALL=(discovery-https claimsets unknown-claimset counts-stable data-v3 rate-limit missing-cert redirect-503
    claimset-reload profiles bad-secret secret-rotation secrets-in-logs bad-checksum warehouse)

[ $# -gt 0 ] || { usage; exit 2; }
case "$1" in
    -h | --help) usage; exit 0 ;;
    list) printf '%s\n' "${ALL[@]}"; exit 0 ;;
    all) set -- "${ALL[@]}" ;;
esac

for tool in docker curl jq; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }; done
[ -f .env ] || { echo "No .env in $KIT_DIR; run ./start.sh first" >&2; exit 2; }
[ ! -f "$ENV_BACKUP" ] || { echo "$ENV_BACKUP exists from an interrupted run; restore or delete it first" >&2; exit 2; }
[ "$(code "$ORIGIN/api")" = 200 ] || { echo "The kit isn't answering at $ORIGIN/api; run ./start.sh first" >&2; exit 2; }

for c in "$@"; do
    fn="check_${c//-/_}"
    declare -F "$fn" >/dev/null || { echo "Unknown check: $c (see: tasks/host-checks.sh list)" >&2; exit 2; }
    "$fn"
done

say "Summary: ${#PASSES[@]} passed, ${#FAILS[@]} failed"
for f in ${FAILS[@]+"${FAILS[@]}"}; do echo "  FAIL $f"; done
if [ "$*" = "${ALL[*]}" ]; then
    echo
    echo "Still manual: open $ORIGIN/pgadmin/ and confirm the preconfigured server connects, and have a"
    echo "fresh reader follow ed-fi-api-v8/README.md on a clean host for each template (FR-DOC-7)."
fi
[ ${#FAILS[@]} -eq 0 ]
