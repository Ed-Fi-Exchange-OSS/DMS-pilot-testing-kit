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
