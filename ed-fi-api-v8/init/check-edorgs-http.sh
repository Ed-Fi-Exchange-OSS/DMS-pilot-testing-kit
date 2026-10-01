#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# check-edorgs-http (Task 14, FR-EDORG-14): proves that http/edorgs.http's five baseline requests
# have not drifted from bootstrap/baseline-edorgs.json -- the single source of truth both
# init/bootstrap.sh (Task 10) and http/edorgs.http read. The two must never diverge in identifiers,
# grade levels, or school categories; this script is how that claim stays checked instead of just
# asserted.
#
# Pure text/JSON comparison -- no network calls, no CMS or DMS token, no database. Runnable alone:
#   sh /init/check-edorgs-http.sh
# with EDORGS_HTTP_FILE and BASELINE_FILE pointed at real files (defaults below assume the standard
# container mounts: the tools service mounts bootstrap/ at /bootstrap and http/ at /http, so run it
# with `docker compose run --rm --no-deps tools sh /init/check-edorgs-http.sh`.
#
# How it works:
#   1. Reads http/edorgs.http's "@name = value" file variables (@seaId, @leaId, and so on).
#   2. Extracts the JSON body of each *uncommented* "POST {{baseUrl}}/data/ed-fi/<resource>" request
#      (the five baseline requests; the commented-out "add more organizations" templates at the
#      bottom of the file are plain text starting with "#", so they never match). This relies on
#      http/edorgs.http formatting each JSON body with the opening "{" and closing "}" alone on their
#      own line, at column 0 -- exactly as Task 14 wrote it.
#   3. Substitutes each "{{name}}" token in those bodies with the file variable's value, so what's
#      compared is exactly what DMS would receive.
#   4. Matches each bootstrap/baseline-edorgs.json entry to the http request with the same resource
#      and the same naturalKey values, then compares the two bodies after canonicalizing (sorted
#      object keys, sorted arrays) so formatting and array order never cause a false mismatch.
#
# Any baseline entry with no matching request, any http request that matches no baseline entry, and
# any matched pair whose bodies differ, is reported by name and fails the script.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP=check-edorgs-http

EDORGS_HTTP_FILE="${EDORGS_HTTP_FILE:-/http/edorgs.http}"
BASELINE_FILE="${BASELINE_FILE:-${BOOTSTRAP_DIR:-/bootstrap}/baseline-edorgs.json}"

[ -f "$EDORGS_HTTP_FILE" ] || die "$STEP" \
    "$EDORGS_HTTP_FILE not found. Run it in the tools service, which mounts http/ at /http:" \
    "docker compose run --rm --no-deps tools sh /init/check-edorgs-http.sh"
[ -f "$BASELINE_FILE" ] || die "$STEP" "$BASELINE_FILE not found"
jq empty "$BASELINE_FILE" 2>/dev/null || die "$STEP" "$BASELINE_FILE is not valid JSON"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/check-edorgs-http.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------------------------
# Step 1: file variables. Only top-level, uncommented "@name = value" lines -- the commented-out
# template blocks never define variables this way, so they are automatically excluded.
# ------------------------------------------------------------------------------------------------

VARS_FILE="$WORK_DIR/vars.txt"
grep -E '^@[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$EDORGS_HTTP_FILE" >"$VARS_FILE" || true

SED_SCRIPT="$WORK_DIR/subst.sed"
: >"$SED_SCRIPT"
while IFS= read -r _cev_line; do
    _cev_name=$(printf '%s\n' "$_cev_line" | sed -E 's/^@([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\1/')
    _cev_value=$(printf '%s\n' "$_cev_line" | sed -E 's/^@[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*//')
    # Escape sed/regex metacharacters in the value so it is safe as a literal replacement.
    _cev_escaped=$(printf '%s' "$_cev_value" | sed -e 's/[&/\]/\\&/g')
    printf 's/{{%s}}/%s/g\n' "$_cev_name" "$_cev_escaped" >>"$SED_SCRIPT"
done <"$VARS_FILE"

[ -s "$SED_SCRIPT" ] || die "$STEP" "no @name = value file variables found in $EDORGS_HTTP_FILE"

# ------------------------------------------------------------------------------------------------
# Step 2: extract each uncommented "POST {{baseUrl}}/data/ed-fi/<resource>" request's JSON body.
# Emits, for each match, a "===RESOURCE:<resource>===" marker line, the body lines verbatim
# (including the delimiting "{" and "}" lines), then "===END===".
# ------------------------------------------------------------------------------------------------

awk '
    BEGIN { state = "idle" }
    {
        line = $0
    }
    state == "idle" {
        if (line ~ /^POST \{\{baseUrl\}\}\/data\/ed-fi\/[A-Za-z]+$/) {
            resource = line
            sub(/^POST \{\{baseUrl\}\}\/data\/ed-fi\//, "", resource)
            state = "afterpost"
        }
        next
    }
    state == "afterpost" {
        if (line == "") { state = "beforebody" }
        next
    }
    state == "beforebody" {
        if (line == "") next
        if (line == "{") {
            state = "inbody"
            body = line "\n"
            next
        }
        state = "idle"
        next
    }
    state == "inbody" {
        body = body line "\n"
        if (line == "}") {
            print "===RESOURCE:" resource "==="
            printf "%s", body
            print "===END==="
            state = "idle"
        }
        next
    }
' "$EDORGS_HTTP_FILE" >"$WORK_DIR/blocks.txt"

BLOCK_COUNT=0
CURRENT_RESOURCE=""
CURRENT_BODY=""
IN_BLOCK=0
while IFS= read -r _blk_line; do
    case "$_blk_line" in
        "===RESOURCE:"*"===")
            CURRENT_RESOURCE=$(printf '%s\n' "$_blk_line" | sed -e 's/^===RESOURCE://' -e 's/===$//')
            CURRENT_BODY=""
            IN_BLOCK=1
            continue
            ;;
        "===END===")
            BLOCK_COUNT=$((BLOCK_COUNT + 1))
            printf '%s' "$CURRENT_RESOURCE" >"$WORK_DIR/block-$BLOCK_COUNT.resource"
            printf '%s' "$CURRENT_BODY" | sed -f "$SED_SCRIPT" >"$WORK_DIR/block-$BLOCK_COUNT.json"
            if grep -q '{{' "$WORK_DIR/block-$BLOCK_COUNT.json"; then
                die "$STEP" \
                    "$EDORGS_HTTP_FILE: a '{{...}}' placeholder in the $CURRENT_RESOURCE request" \
                    "body was not resolved by any @name = value file variable"
            fi
            jq empty "$WORK_DIR/block-$BLOCK_COUNT.json" 2>/dev/null || die "$STEP" \
                "$EDORGS_HTTP_FILE: the $CURRENT_RESOURCE request body is not valid JSON" \
                "after substituting file variables"
            IN_BLOCK=0
            continue
            ;;
    esac
    if [ "$IN_BLOCK" -eq 1 ]; then
        CURRENT_BODY="$CURRENT_BODY$_blk_line
"
    fi
done <"$WORK_DIR/blocks.txt"

[ "$BLOCK_COUNT" -gt 0 ] || die "$STEP" \
    "no 'POST {{baseUrl}}/data/ed-fi/<resource>' requests found in $EDORGS_HTTP_FILE"

log "$STEP" "parsed $BLOCK_COUNT request(s) from $EDORGS_HTTP_FILE"

# canon <file>: prints the file's JSON with object keys and array elements sorted, so formatting and
# array order differences never register as a mismatch.
CANON_FILTER='
def canon:
  if type == "object" then with_entries(.value |= canon) | to_entries | sort_by(.key) | from_entries
  elif type == "array" then map(canon) | sort_by(tojson)
  else .
  end;
canon
'
canon() {
    jq -Sc "$CANON_FILTER" "$1"
}

# ------------------------------------------------------------------------------------------------
# Step 3: match each baseline entry to a parsed block by resource + naturalKey, then compare bodies.
# ------------------------------------------------------------------------------------------------

BASELINE_COUNT=$(jq 'length' "$BASELINE_FILE")
MATCHED_BLOCKS_FILE="$WORK_DIR/matched-blocks.txt"
: >"$MATCHED_BLOCKS_FILE"
FAILURES=0

_i=0
while [ "$_i" -lt "$BASELINE_COUNT" ]; do
    _bl_entry=$(jq -c ".[$_i]" "$BASELINE_FILE")
    _bl_resource=$(printf '%s' "$_bl_entry" | jq -r '.resource')
    _bl_natural_key=$(printf '%s' "$_bl_entry" | jq -c '.naturalKey')
    _bl_body_file="$WORK_DIR/baseline-$_i.json"
    printf '%s' "$_bl_entry" | jq -c '.body' >"$_bl_body_file"
    _bl_key_desc=$(printf '%s' "$_bl_natural_key" \
        | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
    _bl_nk_file="$WORK_DIR/naturalkey-$_i.json"
    printf '%s' "$_bl_natural_key" >"$_bl_nk_file"

    _bl_match=""
    _b=1
    while [ "$_b" -le "$BLOCK_COUNT" ]; do
        if grep -qxF "$_b" "$MATCHED_BLOCKS_FILE" 2>/dev/null; then
            _b=$((_b + 1))
            continue
        fi
        _blk_resource=$(cat "$WORK_DIR/block-$_b.resource")
        _nk_matches=false
        if [ "$_blk_resource" = "$_bl_resource" ]; then
            _nk_matches=$(jq --slurpfile nk "$_bl_nk_file" \
                '. as $body | $nk[0] | to_entries | all(.value == $body[.key])' \
                "$WORK_DIR/block-$_b.json" 2>/dev/null) || _nk_matches=false
        fi
        if [ "$_nk_matches" = "true" ]; then
            _bl_match="$_b"
            break
        fi
        _b=$((_b + 1))
    done

    if [ -z "$_bl_match" ]; then
        log "$STEP" "MISSING: $_bl_resource ($_bl_key_desc) is in $BASELINE_FILE but not in $EDORGS_HTTP_FILE"
        FAILURES=$((FAILURES + 1))
    else
        echo "$_bl_match" >>"$MATCHED_BLOCKS_FILE"
        if [ "$(canon "$WORK_DIR/block-$_bl_match.json")" != "$(canon "$_bl_body_file")" ]; then
            _diff_keys=$(jq -n \
                --argjson a "$(canon "$WORK_DIR/block-$_bl_match.json")" \
                --argjson b "$(canon "$_bl_body_file")" \
                '(($a | keys) + ($b | keys)) | unique | map(select($a[.] != $b[.])) | join(", ")')
            log "$STEP" \
                "MISMATCH: $_bl_resource ($_bl_key_desc): $EDORGS_HTTP_FILE differs from" \
                "$BASELINE_FILE in field(s): $_diff_keys"
            FAILURES=$((FAILURES + 1))
        fi
    fi
    _i=$((_i + 1))
done

# ------------------------------------------------------------------------------------------------
# Step 4: any parsed block never matched to a baseline entry is drift the other direction -- a
# request in http/edorgs.http with no counterpart in baseline-edorgs.json.
# ------------------------------------------------------------------------------------------------

_b=1
while [ "$_b" -le "$BLOCK_COUNT" ]; do
    if ! grep -qxF "$_b" "$MATCHED_BLOCKS_FILE" 2>/dev/null; then
        _extra_resource=$(cat "$WORK_DIR/block-$_b.resource")
        log "$STEP" \
            "EXTRA: a $_extra_resource request in $EDORGS_HTTP_FILE matches no entry in $BASELINE_FILE" \
            "($(cat "$WORK_DIR/block-$_b.json" | jq -c .))"
        FAILURES=$((FAILURES + 1))
    fi
    _b=$((_b + 1))
done

if [ "$FAILURES" -gt 0 ]; then
    die "$STEP" "$EDORGS_HTTP_FILE does not match $BASELINE_FILE ($FAILURES issue(s), see above)"
fi

log "$STEP" "PASS: $EDORGS_HTTP_FILE matches $BASELINE_FILE ($BASELINE_COUNT/$BASELINE_COUNT records)"
