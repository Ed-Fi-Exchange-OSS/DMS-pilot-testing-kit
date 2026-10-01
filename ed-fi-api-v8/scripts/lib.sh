#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Shared Bash helpers for the Task 12 lifecycle scripts (start.sh, stop.sh, reset.sh, bootstrap.sh)
# and available to any later host wrapper that wants them. Source it, don't execute it:
#   . "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lib.sh"
# This file requires Bash (arrays, ${BASH_SOURCE[0]}); the one-shot container scripts under
# ed-fi-api-v8/init/ are separate and stay POSIX sh (see init/lib.sh).
#
# Public API (everything else here is a private helper, prefixed with an underscore):
#   KIT_DIR                          absolute path of ed-fi-api-v8/, computed from this file's own
#                                     location -- independent of the caller's working directory
#   kit_log / kit_warn / kit_die     stdout / stderr(WARNING) / stderr(ERROR)+exit 1
#   kit_require_docker                docker on PATH and the daemon reachable, else kit_die
#   kit_require_compose               Compose v2 available, else kit_die
#   kit_compose <args...>            runs `docker compose <args...>` from KIT_DIR (never --env-file:
#                                     the included compose files read ./.env themselves)
#   kit_env_get <NAME> [default]     read a value from .env (or the default if unset/absent)
#   kit_env_has <NAME>               true if NAME= appears in .env
#   kit_env_set <NAME> <VALUE>       replace or append NAME=VALUE in .env
#   kit_generate_secret <len> [full|safe]
#                                     a local secret of exactly <len> characters with at least one
#                                     lowercase, one uppercase, one digit, and one special character.
#                                     "safe" (default "full") drops ';' from the special-character
#                                     pool -- see the comment on _KIT_SPECIAL_SAFE below.
#   kit_ensure_env                   create .env from .env.example with generated secrets if it
#                                     doesn't exist; otherwise warn (by name) about any variable in
#                                     .env.example that .env is missing. Never modifies an existing
#                                     .env value, and never prints a secret value.
#   kit_ensure_certs                 generate ssl/server.{crt,key} if either is missing
#   kit_ensure_dirs                  create .runtime/ and ${LOG_DIR:-./logs}/nginx
#   kit_compose_failures             one "service<TAB>reason" line per exited(non-zero)/unhealthy
#                                     container, from `docker compose ps -a --format json`
#   kit_show_failure_logs <service>  last 20 lines of the service's logs, plus the full-log command
#   kit_print_urls                   the kit's participant-facing URLs, from .env
#   kit_current_template             the template marker row from the database, falling back to
#                                     .env's DATABASE_TEMPLATE if the query fails or returns nothing
#   kit_stack_running [service]      true if <service> (default "dms") is running

# Git Bash on Windows otherwise rewrites container paths such as /init/... into Windows paths
# (spike-notes Q1). Harmless when not on Git Bash.
export MSYS_NO_PATHCONV=1

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
_KIT_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1007
KIT_DIR=$(CDPATH= cd -- "$_KIT_LIB_DIR/.." && pwd)

kit_log() { printf '%s\n' "$*"; }
kit_warn() { printf 'WARNING: %s\n' "$*" >&2; }
kit_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# kit_compose <args...> -- always from KIT_DIR, per compose.yml's header warning: the included files
# read ./.env, so this kit never passes --env-file, and every invocation must run from ed-fi-api-v8/.
kit_compose() {
    (cd "$KIT_DIR" && docker compose "$@")
}

kit_require_docker() {
    command -v docker >/dev/null 2>&1 ||
        kit_die "Docker was not found on PATH. Install Docker Desktop (Windows/macOS) or Docker" \
            "Engine (Linux): https://docs.docker.com/get-docker/"
    docker info >/dev/null 2>&1 ||
        kit_die "Docker is installed but not responding (docker info failed). Start Docker Desktop" \
            "(or the Docker daemon) and try again."
}

kit_require_compose() {
    docker compose version >/dev/null 2>&1 ||
        kit_die "Docker Compose v2 was not found (docker compose version failed). Update Docker" \
            "Desktop, or install the compose-plugin: https://docs.docker.com/compose/install/"
}

# ----------------------------------------------------------------------------------------------
# .env access
# ----------------------------------------------------------------------------------------------

_kit_env_file() { printf '%s' "$KIT_DIR/.env"; }

kit_env_has() {
    _keh_name="$1"
    _keh_file=$(_kit_env_file)
    [ -f "$_keh_file" ] && grep -qE "^${_keh_name}=" "$_keh_file"
}

kit_env_get() {
    _keg_name="$1"
    _keg_default="${2:-}"
    _keg_file=$(_kit_env_file)
    if [ ! -f "$_keg_file" ] || ! grep -qE "^${_keg_name}=" "$_keg_file"; then
        printf '%s' "$_keg_default"
        return 0
    fi
    grep -E "^${_keg_name}=" "$_keg_file" | tail -n1 | cut -d'=' -f2-
}

# kit_env_set <NAME> <VALUE> -- replaces an existing NAME= line in place (preserving every other
# line untouched, including any '=' inside other values) or appends NAME=VALUE if absent. Requires
# .env to already exist.
kit_env_set() {
    _kes_name="$1"
    _kes_value="$2"
    _kes_file=$(_kit_env_file)
    [ -f "$_kes_file" ] || kit_die "$_kes_file does not exist"
    _kes_tmp=$(mktemp "${TMPDIR:-/tmp}/kit-env.XXXXXX")
    if grep -qE "^${_kes_name}=" "$_kes_file"; then
        awk -v k="$_kes_name" -v v="$_kes_value" -F= '
            $1 == k { print k "=" v; next }
            { print }
        ' "$_kes_file" >"$_kes_tmp"
    else
        cat "$_kes_file" >"$_kes_tmp"
        printf '%s=%s\n' "$_kes_name" "$_kes_value" >>"$_kes_tmp"
    fi
    mv "$_kes_tmp" "$_kes_file"
}

# ----------------------------------------------------------------------------------------------
# Secret generation. LOCAL DEVELOPMENT ONLY -- see .env.example's header. Every generated value has
# at least one lowercase letter, one uppercase letter, one digit, and one special character, which
# satisfies both the 32-128 character client-secret rule and the exactly-32-character
# CMS_DATABASE_ENCRYPTION_KEY rule (call with the exact length wanted).
# ----------------------------------------------------------------------------------------------

_KIT_LOWER='abcdefghijklmnopqrstuvwxyz'
_KIT_UPPER='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
_KIT_DIGIT='0123456789'
# No '$': Compose interpolates it in .env values, which would corrupt the secret.
_KIT_SPECIAL_FULL='!@#%^&*()-_=+[]{}:;,.?'
# Same set without ';'. POSTGRES_PASSWORD is embedded, unescaped, into semicolon-delimited
# ADO.NET/Npgsql-style connection strings elsewhere in the kit (compose.core.yml
# DatabaseSettings__DatabaseConnection and DATABASE_CONNECTION_STRING_ADMIN, and the connection
# string init/datastore.sh registers with CMS); a literal ';' in the password would truncate or
# corrupt those. PGADMIN_DEFAULT_PASSWORD and CMS_DATABASE_ENCRYPTION_KEY use the same safe pool
# out of caution, even though neither is known to need it today.
_KIT_SPECIAL_SAFE='!@#%^&*()-_=+[]{}:,.?'

# _kit_random_from_pool <pool> <count> -- <count> characters drawn from <pool> using OpenSSL's CSPRNG
# (one openssl invocation for the whole batch, not per character). Uniformity has a slight bias from
# the byte % pool_len reduction, which is immaterial for a local-only development secret.
_kit_random_from_pool() {
    local pool="$1" count="$2" pool_len out byte idx
    [ "$count" -gt 0 ] || {
        printf ''
        return 0
    }
    pool_len=${#pool}
    out=""
    for byte in $(openssl rand "$count" | od -An -tu1); do
        idx=$((byte % pool_len))
        out="$out${pool:idx:1}"
    done
    printf '%s' "$out"
}

# _kit_shuffle_string <s> -- a Fisher-Yates shuffle of <s>'s characters, so the guaranteed
# lowercase/uppercase/digit/special characters kit_generate_secret injects aren't always in the
# first four positions.
_kit_shuffle_string() {
    local s="$1" n i j tmp byte
    n=${#s}
    local -a arr=()
    i=0
    while [ "$i" -lt "$n" ]; do
        arr+=("${s:i:1}")
        i=$((i + 1))
    done
    i=$((n - 1))
    if [ "$i" -gt 0 ]; then
        for byte in $(openssl rand "$n" | od -An -tu1); do
            [ "$i" -le 0 ] && break
            j=$((byte % (i + 1)))
            tmp="${arr[i]}"
            arr[i]="${arr[j]}"
            arr[j]="$tmp"
            i=$((i - 1))
        done
    fi
    out=""
    for tmp in "${arr[@]}"; do
        out="$out$tmp"
    done
    printf '%s' "$out"
}

# _kit_avoid_leading_dash <s> -- swaps the first and last character if <s> starts with '-'. Nothing
# in this kit passes a generated secret as a bare CLI argument today (every call site embeds it in a
# larger string: KEY=VALUE, "key:secret", "client_secret=value"), but a value that could be mistaken
# for a flag by some future consumer is a cheap footgun to remove at generation time.
_kit_avoid_leading_dash() {
    local s="$1" n first last
    n=${#s}
    first="${s:0:1}"
    if [ "$first" = "-" ] && [ "$n" -gt 1 ]; then
        last="${s:n-1:1}"
        s="${last}${s:1:n-2}${first}"
    fi
    printf '%s' "$s"
}

# kit_generate_secret <length> [full|safe] -- see the pool comments above. <length> must be >= 4.
kit_generate_secret() {
    local len="$1" pool_name="${2:-full}" special all guaranteed rest
    if [ "$pool_name" = "safe" ]; then
        special="$_KIT_SPECIAL_SAFE"
    else
        special="$_KIT_SPECIAL_FULL"
    fi
    all="$_KIT_LOWER$_KIT_UPPER$_KIT_DIGIT$special"
    guaranteed="$(_kit_random_from_pool "$_KIT_LOWER" 1)$(_kit_random_from_pool "$_KIT_UPPER" 1)"
    guaranteed="$guaranteed$(_kit_random_from_pool "$_KIT_DIGIT" 1)$(_kit_random_from_pool "$special" 1)"
    rest="$(_kit_random_from_pool "$all" "$((len - 4))")"
    _kit_avoid_leading_dash "$(_kit_shuffle_string "$guaranteed$rest")"
}

# ----------------------------------------------------------------------------------------------
# start.sh building blocks (reusable by any future wrapper)
# ----------------------------------------------------------------------------------------------

# kit_ensure_env -- see the public API comment above.
kit_ensure_env() {
    local env_file example_file line key missing default_line
    env_file=$(_kit_env_file)
    example_file="$KIT_DIR/.env.example"
    [ -f "$example_file" ] || kit_die ".env.example not found in $KIT_DIR"

    if [ ! -f "$env_file" ]; then
        kit_log "No .env found. Creating one from .env.example with freshly generated local secrets."
        cp "$example_file" "$env_file"

        kit_env_set POSTGRES_PASSWORD "$(kit_generate_secret 32 safe)"
        kit_env_set CMS_SERVICE_CLIENT_SECRET "$(kit_generate_secret 48 full)"
        kit_env_set CMS_READONLY_CLIENT_SECRET "$(kit_generate_secret 48 full)"
        kit_env_set CMS_ADMIN_CLIENT_SECRET "$(kit_generate_secret 48 full)"
        kit_env_set CMS_DATABASE_ENCRYPTION_KEY "$(kit_generate_secret 32 safe)"
        kit_env_set CMS_IDENTITY_ENCRYPTION_KEY "$(openssl rand -base64 32 | tr -d '\n')"
        kit_env_set PGADMIN_DEFAULT_PASSWORD "$(kit_generate_secret 32 safe)"

        kit_log "Generated local secrets for POSTGRES_PASSWORD, CMS_SERVICE_CLIENT_SECRET,"
        kit_log "CMS_READONLY_CLIENT_SECRET, CMS_ADMIN_CLIENT_SECRET, CMS_DATABASE_ENCRYPTION_KEY,"
        kit_log "CMS_IDENTITY_ENCRYPTION_KEY, and PGADMIN_DEFAULT_PASSWORD."
        kit_log "Values are never printed; see $env_file if you need one of them."
        return 0
    fi

    missing=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#* | "") continue ;;
        esac
        key=${line%%=*}
        [ -n "$key" ] || continue
        kit_env_has "$key" || missing="$missing $key"
    done <"$example_file"

    if [ -n "$missing" ]; then
        kit_warn ".env exists but is missing variables present in .env.example:$missing"
        kit_warn "Add them to $env_file (existing values in .env are never changed automatically)."
        kit_warn "Defaults from .env.example:"
        for key in $missing; do
            default_line=$(grep -E "^${key}=" "$example_file" | head -n1)
            kit_warn "  $default_line"
        done
    fi
}

kit_ensure_certs() {
    local crt="$KIT_DIR/ssl/server.crt" key="$KIT_DIR/ssl/server.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        kit_log "TLS certificate missing; generating a local self-signed certificate."
        "$KIT_DIR/ssl/generate-certificate.sh" ||
            kit_die "certificate generation failed; see ssl/generate-certificate.sh --help"
    fi
}

kit_ensure_dirs() {
    local log_dir
    log_dir=$(kit_env_get LOG_DIR "./logs")
    case "$log_dir" in
        /*) : ;;
        *) log_dir="$KIT_DIR/$log_dir" ;;
    esac
    mkdir -p "$KIT_DIR/.runtime" "$log_dir/nginx" ||
        kit_die "could not create $KIT_DIR/.runtime or $log_dir/nginx"
}

# ----------------------------------------------------------------------------------------------
# Failure diagnosis, used by start.sh (FR-LIFE-9)
# ----------------------------------------------------------------------------------------------

# `docker compose ps --format json` has printed either one JSON object per line, or a single JSON
# array, depending on the Compose version. This normalizes either shape to one object per line.
_kit_normalize_json_objects() {
    tr -d '\n' | sed -E -e 's/^\[//' -e 's/\]$//' -e 's/\}[[:space:]]*,?[[:space:]]*\{/}\n{/g'
}

# _kit_json_field <json-object> <field-name> -- a bare grep/sed field extractor (no jq dependency on
# the host), good enough for the flat string/number fields `compose ps --format json` emits.
_kit_json_field() {
    local obj="$1" name="$2" match
    match=$(printf '%s' "$obj" | grep -o "\"$name\":\"[^\"]*\"" | head -n1)
    if [ -n "$match" ]; then
        printf '%s' "$match" | sed -E 's/^"[^"]+":"(.*)"$/\1/'
        return 0
    fi
    match=$(printf '%s' "$obj" | grep -o "\"$name\":[0-9-]*" | head -n1)
    printf '%s' "$match" | sed -E "s/^\"$name\"://"
}

# kit_compose_failures -- one "service<TAB>reason" line per container that is unhealthy, or exited
# with a non-zero code (covers both a failed one-shot init step and a long-running service that
# died). Prints nothing (and returns success) if every container looks fine, or if the query itself
# fails (for example, no containers exist yet).
kit_compose_failures() {
    local raw obj service state health exitcode reason
    raw=$(kit_compose ps -a --format json 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    # `|| [ -n "$obj" ]`: the normalized stream's last line has no trailing newline, and a `read`
    # that hits EOF mid-line still populates $obj but returns non-zero -- without this, the last
    # container in the list would be silently dropped from the loop.
    while IFS= read -r obj || [ -n "$obj" ]; do
        [ -n "$obj" ] || continue
        service=$(_kit_json_field "$obj" Service)
        [ -n "$service" ] || continue
        state=$(_kit_json_field "$obj" State)
        health=$(_kit_json_field "$obj" Health)
        exitcode=$(_kit_json_field "$obj" ExitCode)
        reason=""
        if [ "$health" = "unhealthy" ]; then
            reason="unhealthy"
        elif [ "$state" = "exited" ] && [ -n "$exitcode" ] && [ "$exitcode" != "0" ]; then
            reason="exited with code $exitcode"
        fi
        [ -n "$reason" ] && printf '%s\t%s\n' "$service" "$reason"
    done < <(printf '%s' "$raw" | _kit_normalize_json_objects)
}

kit_show_failure_logs() {
    local svc="$1"
    kit_log ""
    kit_log "----- last 20 lines of '$svc' -----"
    kit_compose logs --no-color --tail=20 "$svc" 2>&1 | sed 's/^/  /'
    kit_log "Full logs: (cd \"$KIT_DIR\" && docker compose logs $svc)"
}

# ----------------------------------------------------------------------------------------------
# Success output
# ----------------------------------------------------------------------------------------------

kit_print_urls() {
    local origin dms_base cms_base
    origin=$(kit_env_get PUBLIC_ORIGIN "https://localhost")
    dms_base=$(kit_env_get DMS_PATH_BASE "api")
    cms_base=$(kit_env_get CMS_PATH_BASE "config")
    kit_log "  API / Discovery:  $origin/$dms_base"
    kit_log "  Token endpoint:   $origin/$dms_base/oauth/token"
    kit_log "  CMS config:       $origin/$cms_base"
    kit_log "  Swagger UI:       $origin/swagger"
    kit_log "  PGAdmin:          $origin/pgadmin"
}

# kit_current_template -- the most recent kit.initialization.template row, read live from the
# database so a stale .env DATABASE_TEMPLATE can't misreport what's actually loaded; falls back to
# .env if the query fails (for example, the database isn't reachable) or returns no row yet.
kit_current_template() {
    local db val
    db=$(kit_env_get POSTGRES_DB_NAME "edfi_datamanagementservice")
    val=$(kit_compose exec -T db psql -U postgres -d "$db" -tAc \
        "SELECT template FROM kit.initialization ORDER BY completed_at DESC LIMIT 1" 2>/dev/null |
        tr -d '\r\n ')
    [ -n "$val" ] || val=$(kit_env_get DATABASE_TEMPLATE "minimal")
    printf '%s' "$val"
}

# kit_stack_running [service] -- true (exit 0) if <service> (default "dms") is currently running.
# Used to fail fast with "run start first" instead of letting `docker compose run` bring up
# dependencies on its own (bootstrap.sh, and later new-credential.sh / smoke-test.sh).
kit_stack_running() {
    local service="${1:-dms}"
    kit_compose ps --status running --services 2>/dev/null | grep -qx "$service"
}
