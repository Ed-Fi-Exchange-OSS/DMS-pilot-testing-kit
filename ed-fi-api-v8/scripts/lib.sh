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
#   kit_require_compose               Compose 2.20+ available, else kit_die
#   kit_compose <args...>            runs `docker compose <args...>` from KIT_DIR (never --env-file:
#                                     the included compose files read ./.env themselves)
#   kit_compose_tee <file> <args...> same, streaming stdout+stderr live while also copying them to
#                                     <file>; returns Compose's own exit status
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
#   kit_compose_failures [up-output-file]
#                                     one "service<TAB>reason" line per failing service: those
#                                     named in Compose's `up --wait` errors in <up-output-file>
#                                     first, then any unhealthy, exited(non-zero), never-started, or
#                                     suspect one-shot init- container from `docker compose ps -a`
#   kit_show_failure_logs <service>  last 20 lines of the service's logs, plus the full-log command
#   kit_show_up_failure <up-output-file>
#                                     the full startup-failure report: Compose's own error lines,
#                                     each failing service with its recent logs, and the inspect
#                                     commands
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

# kit_compose_tee <file> <args...> -- kit_compose, with stdout and stderr (where Compose writes its
# progress and errors) streamed live and also copied to <file>, so a failed `up --wait` can be
# diagnosed from Compose's own messages afterwards. Returns Compose's exit status, not tee's. Since
# the output is now a pipe rather than a terminal, Compose shows its plain (line-by-line) progress.
kit_compose_tee() {
    local file="$1"
    shift
    kit_compose "$@" 2>&1 | tee "$file"
    return "${PIPESTATUS[0]}"
}

kit_require_docker() {
    command -v docker >/dev/null 2>&1 ||
        kit_die "Docker was not found on PATH. Install Docker Desktop (Windows/macOS) or Docker" \
            "Engine (Linux): https://docs.docker.com/get-docker/"
    docker info >/dev/null 2>&1 ||
        kit_die "Docker is installed but not responding (docker info failed). Start Docker Desktop" \
            "(or the Docker daemon) and try again."
}

# compose.yml uses top-level `include`, which needs Compose 2.20 or later.
kit_require_compose() {
    local version major minor
    version=$(docker compose version --short 2>/dev/null) ||
        kit_die "Docker Compose v2 was not found (docker compose version failed). Update Docker" \
            "Desktop, or install the compose-plugin: https://docs.docker.com/compose/install/"
    # --short prints e.g. 2.29.7, v2.20.0, or 2.40.3-desktop.1.
    version=${version#v}
    major=${version%%.*}
    minor=${version#*.}
    minor=${minor%%[!0-9]*}
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        kit_warn "Could not read the Docker Compose version ('$version'); this kit needs 2.20" \
            "or later."
        return 0
    fi
    if ((major < 2 || (major == 2 && minor < 20))); then
        kit_die "Docker Compose $version is too old; this kit needs 2.20 or later. Update Docker" \
            "Desktop, or install the compose-plugin: https://docs.docker.com/compose/install/"
    fi
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
# No '&' or '=': CMS_ADMIN_CLIENT_SECRET (and the other CMS_*_CLIENT_SECRET values generated from
# this pool) is embedded unescaped into application/x-www-form-urlencoded request bodies built by
# naive string concatenation -- see http/claimset-test.http's
# "grant_type=client_credentials&client_id=...&client_secret={{CMS_ADMIN_CLIENT_SECRET}}&scope=..."
# line, where the VS Code REST Client extension substitutes the placeholder as literal text without
# urlencoding it. A literal '&' in the secret would be read as a field separator, and a literal '='
# would make everything after it in that chunk part of the wrong field, corrupting the request.
_KIT_SPECIAL_FULL='!@#%^*()-_+[]{}:;,.?'
# Same set without ';'. POSTGRES_PASSWORD is embedded, unescaped, into semicolon-delimited
# ADO.NET/Npgsql-style connection strings elsewhere in the kit (compose.core.yml
# DatabaseSettings__DatabaseConnection and DATABASE_CONNECTION_STRING_ADMIN, and the connection
# string init/datastore.sh registers with CMS); a literal ';' in the password would truncate or
# corrupt those. PGADMIN_DEFAULT_PASSWORD and CMS_DATABASE_ENCRYPTION_KEY use the same safe pool
# out of caution, even though neither is known to need it today.
_KIT_SPECIAL_SAFE='!@#%^*()-_+[]{}:,.?'

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
# array, depending on the Compose version. This normalizes either shape to one object per line. It
# tracks brace depth (skipping braces inside strings) rather than splitting on "},{", because each
# container object itself contains nested objects -- for example one per published port, under
# "Publishers" -- and splitting those apart would separate a container's Health from its Service.
_kit_normalize_json_objects() {
    awk '
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (instr) {
                    obj = obj c
                    if (esc) esc = 0
                    else if (c == "\\") esc = 1
                    else if (c == "\"") instr = 0
                    continue
                }
                if (c == "{") depth++
                if (depth > 0) obj = obj c
                if (c == "\"" && depth > 0) instr = 1
                if (c == "}" && depth > 0) {
                    depth--
                    if (depth == 0) {
                        print obj
                        obj = ""
                    }
                }
            }
        }
    '
}

# _kit_json_field <json-object> <field-name> -- a bare grep/sed field extractor (no jq dependency on
# the host), good enough for the flat string/number fields `compose ps --format json` emits.
_kit_json_field() {
    local obj="$1" name="$2" match
    match=$(printf '%s' "$obj" | grep -oE "\"$name\":[[:space:]]*\"[^\"]*\"" | head -n1 || true)
    if [ -n "$match" ]; then
        printf '%s' "$match" | sed -E 's/^"[^"]+":[[:space:]]*"(.*)"$/\1/'
        return 0
    fi
    match=$(printf '%s' "$obj" | grep -oE "\"$name\":[[:space:]]*-?[0-9]+" | head -n1 || true)
    printf '%s' "$match" | sed -E "s/^\"$name\":[[:space:]]*//"
}

# _kit_in_list <item> <newline-separated list> -- true if <item> is exactly one of the lines.
# (Plain lists rather than associative arrays, which macOS's stock Bash 3.2 doesn't have.)
_kit_in_list() {
    [ -n "$1" ] && printf '%s\n' "$2" | grep -qxF -- "$1"
}

# The failure messages `docker compose up --wait` itself prints, in Compose's wording:
#   container <name> has no healthcheck configured
#   container <name> exited (<code>)
#   container <name> is unhealthy
#   service "<service>" didn't complete successfully: exit <code>
# often behind a prefix such as `dependency failed to start: `. Matched case-insensitively, and
# loosely enough to survive small wording changes between Compose versions.
_KIT_WAIT_ERROR_RE='container [^ ]+ (has no healthcheck configured|exited \(-?[0-9]+\)'
_KIT_WAIT_ERROR_RE="$_KIT_WAIT_ERROR_RE"'|is unhealthy)'
_KIT_WAIT_ERROR_RE="$_KIT_WAIT_ERROR_RE"'|service "?[^" ]+"? didn.?t complete successfully'

# _kit_plain_output <file> -- <file> without carriage returns or ANSI color/cursor sequences.
_kit_plain_output() {
    [ -f "$1" ] || return 0
    tr -d '\r' <"$1" | sed "s/$(printf '\033')\[[0-9;?]*[A-Za-z]//g"
}

# _kit_compose_wait_errors <up-output-file> -- the distinct --wait error lines in captured `up`
# output, trimmed, in the order Compose printed them. Prints nothing if there are none.
_kit_compose_wait_errors() {
    _kit_plain_output "$1" | { grep -iE "$_KIT_WAIT_ERROR_RE" || true; } |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk '!seen[$0]++'
}

# _kit_last_output_lines <up-output-file> <count> -- the last <count> non-blank lines, trimmed.
_kit_last_output_lines() {
    _kit_plain_output "$1" | { grep -v '^[[:space:]]*$' || true; } | tail -n "$2" |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# _kit_completion_dependencies -- the services some other service depends on with
# `condition: service_completed_successfully`, one per line, from `docker compose config --format
# json` (which is held in memory only: it contains the interpolated .env secrets). Returns non-zero
# if the configuration couldn't be read, so the caller can tell "none" from "unknown".
_kit_completion_dependencies() {
    local cfg entry_re
    cfg=$(kit_compose config --format json 2>/dev/null) || return 1
    [ -n "$cfg" ] || return 1
    # Each depends_on entry looks like "<service>": {"condition": "...", "required": true, ...}.
    entry_re='"[^"]+":[[:space:]]*\{[^{}]*"condition":[[:space:]]*"service_completed_successfully"'
    printf '%s' "$cfg" | tr -d '\r\n' | { grep -oE "$entry_re" || true; } |
        sed -E 's/^"([^"]+)".*/\1/' | sort -u
    return 0
}

# _kit_container_problem <json-object> <named:0|1> <deps-known:0|1> <completion-deps> -- the reason
# a container looks like a startup failure, or nothing if it looks fine. <named> is 1 if Compose's
# own --wait error named it; <completion-deps> is _kit_completion_dependencies' output.
_kit_container_problem() {
    local obj="$1" named="$2" deps_known="$3" deps="$4" service state health exitcode
    service=$(_kit_json_field "$obj" Service)
    state=$(_kit_json_field "$obj" State)
    health=$(_kit_json_field "$obj" Health)
    exitcode=$(_kit_json_field "$obj" ExitCode)
    if [ "$health" = "unhealthy" ]; then
        printf 'unhealthy'
    elif [ "$state" = "exited" ] && [ -n "$exitcode" ] && [ "$exitcode" != "0" ]; then
        printf 'exited with code %s' "$exitcode"
    elif [ "$state" = "created" ]; then
        printf 'never started (a dependency likely failed or was not satisfied)'
    elif [[ "$service" == init-* ]] && { [ "$state" = "exited" ] || [ "$state" = "running" ]; } &&
        { { [ "$deps_known" = 1 ] && ! _kit_in_list "$service" "$deps"; } ||
            { [ "$deps_known" = 0 ] && [ "$named" = 1 ]; }; }; then
        # A one-shot init step that finished (or is still going) is only a problem if `--wait` was
        # waiting for it to be *healthy* -- which is what Compose does for any service that nothing
        # else waits on with service_completed_successfully.
        if [ "$state" = "exited" ]; then
            printf 'exited with code 0'
        else
            printf 'still running'
        fi
        printf '; Compose --wait may have checked this one-shot service as a long-running one,'
        printf ' because no other service depends on it with'
        printf ' condition: service_completed_successfully'
    elif [ "$named" = 1 ]; then
        printf "named in Compose's error above (state: %s)" "$state"
    fi
}

# kit_compose_failures [up-output-file] -- one "service<TAB>reason" line per failing service, each
# service at most once: first the services Compose's own --wait errors in <up-output-file> name
# (container names map back to services through `docker compose ps -a`, never by trimming the
# name), then any other container that is unhealthy, exited non-zero, never started, or is a
# one-shot init- service --wait likely treated as long-running. Prints nothing (and returns
# success) if nothing can be identified, or if the queries themselves fail.
kit_compose_failures() {
    local up_log="${1:-}" errors="" named_containers="" named_services="" raw objects
    local deps="" deps_known=0 seen="" pass obj service name named reason svc
    if [ -n "$up_log" ]; then
        errors=$(_kit_compose_wait_errors "$up_log")
        named_containers=$(printf '%s\n' "$errors" |
            { grep -oiE 'container [^ ]+ (has no|exited|is unhealthy)' || true; } |
            sed -E 's/^[^ ]+ \/?([^ ]+) .*/\1/')
        named_services=$(printf '%s\n' "$errors" |
            { grep -oiE 'service "?[^" ]+"? didn.?t' || true; } |
            sed -E 's/^[^ ]+ "?([^" ]+)"? .*/\1/')
    fi
    raw=$(kit_compose ps -a --format json 2>/dev/null) || raw=""
    objects=$(printf '%s' "$raw" | _kit_normalize_json_objects)
    if deps=$(_kit_completion_dependencies); then
        deps_known=1
    fi

    # Two passes over the same containers, so the services Compose named are reported first.
    for pass in named other; do
        while IFS= read -r obj; do
            [ -n "$obj" ] || continue
            service=$(_kit_json_field "$obj" Service)
            [ -n "$service" ] || continue
            name=$(_kit_json_field "$obj" Name)
            named=0
            if _kit_in_list "$name" "$named_containers" ||
                _kit_in_list "$service" "$named_services"; then
                named=1
            fi
            { [ "$pass" = named ] && [ "$named" = 1 ]; } ||
                { [ "$pass" = other ] && [ "$named" = 0 ]; } || continue
            _kit_in_list "$service" "$seen" && continue
            reason=$(_kit_container_problem "$obj" "$named" "$deps_known" "$deps")
            [ -n "$reason" ] || continue
            printf '%s\t%s\n' "$service" "$reason"
            seen="$seen"$'\n'"$service"
        done <<<"$objects"
    done

    # A service Compose named by service name that `ps -a` doesn't list at all.
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        _kit_in_list "$svc" "$seen" && continue
        printf "%s\tnamed in Compose's error above (no container found)\n" "$svc"
        seen="$seen"$'\n'"$svc"
    done <<<"$named_services"
}

kit_show_failure_logs() {
    local svc="$1"
    kit_log ""
    kit_log "----- last 20 lines of '$svc' -----"
    # `|| true`: a logs failure must not end the failure report early under start.sh's `set -e`.
    kit_compose logs --no-color --tail=20 "$svc" 2>&1 | sed 's/^/  /' || true
    kit_log "Full logs: (cd \"$KIT_DIR\" && docker compose logs $svc)"
}

# kit_show_up_failure <up-output-file> -- what start.sh prints after `up --wait` fails, given that
# command's captured output: Compose's own --wait error lines (or, if none is recognized, its last
# few output lines), then each failing service with its recent logs, then the inspect commands.
kit_show_up_failure() {
    local up_log="$1" errors last failures svc reason
    kit_log ""
    kit_log "Startup did not complete."
    errors=$(_kit_compose_wait_errors "$up_log")
    if [ -n "$errors" ]; then
        kit_log "Compose reported:"
        printf '%s\n' "$errors" | sed 's/^/  /'
    else
        last=$(_kit_last_output_lines "$up_log" 5)
        if [ -n "$last" ]; then
            kit_log "Compose did not report a recognized --wait error. Its last output lines were:"
            printf '%s\n' "$last" | sed 's/^/  /'
        else
            kit_log "Compose printed no output."
        fi
    fi
    kit_log ""
    kit_log "Checking service status..."
    failures=$(kit_compose_failures "$up_log" || true)
    if [ -n "$failures" ]; then
        while IFS="$(printf '\t')" read -r svc reason; do
            [ -n "$svc" ] || continue
            kit_log "FAILED: $svc ($reason)"
            kit_show_failure_logs "$svc"
        done <<<"$failures"
    else
        kit_log "Could not identify a failing service from Compose's output or its service status."
    fi
    kit_log ""
    kit_log "Inspect further with:"
    kit_log "  (cd \"$KIT_DIR\" && docker compose ps -a)"
    kit_log "  (cd \"$KIT_DIR\" && docker compose logs)"
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
