#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-api-schema (Task 4): stages the DS 5.2 ApiSchema files DMS needs into the api-schema volume,
# sourced from the pinned DMS image's own /app/ApiSchema rather than the NuGet package (plan.md
# decision 10) -- no network access, and it always matches the DMS build exactly. Runs as root
# (image: ${DMS_IMAGE}; a fresh named volume is root-owned), with the volume mounted at /stage
# rather than /app/ApiSchema so Docker's copy-up never fires (spike-notes Q3): an empty volume first
# mounted at the image's own /app/ApiSchema would be filled with the image's core+TPDM content
# before this script ever got a chance to run.
#
# The DMS image's base OS and shell utilities aren't confirmed beyond jq (spike-notes Q3), so every
# external tool this script uses is checked with `command -v` up front, and lib.sh (also plain sh)
# is sourced only for log/die/require_env.
#
# SRC/DEST default to the image's real paths but are overridable, so this script can be exercised
# against a fake source tree without a container.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_TOOLS=check-tools
STEP_ENV=validate-env
STEP_CHECK=check-existing
STEP_VERIFY=verify-source
STEP_STAGE=stage
STEP_DONE=api-schema

SRC="${API_SCHEMA_SRC:-/app/ApiSchema}"
DEST="${API_SCHEMA_DEST:-/stage}"
PKG_NAME="EdFi.DataStandard52.ApiSchema"
PKG_REL="Packages/$PKG_NAME"

# ------------------------------------------------------------------------------------------------
# Step a: every external tool this script calls, checked before any of them is used.
# ------------------------------------------------------------------------------------------------

_as_missing=""
for _as_tool in jq sha256sum cp find mkdir rm chmod dirname; do
    command -v "$_as_tool" >/dev/null 2>&1 || _as_missing="$_as_missing $_as_tool"
done
if [ -n "$_as_missing" ]; then
    die "$STEP_TOOLS" "missing required tool(s):$_as_missing"
fi
unset _as_tool _as_missing
log "$STEP_TOOLS" "jq, sha256sum, cp, find, mkdir, rm, chmod, dirname all present"

require_env "$STEP_ENV" API_SCHEMA_SHA256

[ -d "$SRC" ] || die "$STEP_ENV" "API_SCHEMA_SRC ($SRC) does not exist or is not a directory"
mkdir -p "$DEST" || die "$STEP_ENV" "cannot create/access API_SCHEMA_DEST ($DEST)"

# expected_manifest -> the core-only bootstrap manifest on stdout (spike-notes Q3): version 1, one
# project (ed-fi), with every path under Packages/EdFi.DataStandard52.ApiSchema/. Printed key-sorted
# and compact so it can be diffed byte-for-byte against whatever is already on disk.
expected_manifest() {
    jq -nSc \
        --arg schemaPath "$PKG_REL/ApiSchema.json" \
        --arg discoverySpecPath "$PKG_REL/discovery-spec.json" \
        --arg xsdDirectory "$PKG_REL/xsd" \
        '{
            version: 1,
            projects: [{
                projectName: "Ed-Fi",
                projectEndpointName: "ed-fi",
                isExtensionProject: false,
                schemaPath: $schemaPath,
                discoverySpecPath: $discoverySpecPath,
                xsdDirectory: $xsdDirectory
            }]
        }'
}

# sha256_of <file> -> the hex digest on stdout. Reads the digest out of `sha256sum`'s own output
# with a parameter expansion rather than cut/awk, so those don't need to be on the tool check above.
sha256_of() {
    _sha_line=$(sha256sum "$1") || return 1
    printf '%s' "${_sha_line%% *}"
}

# ------------------------------------------------------------------------------------------------
# Step b: is $DEST already exactly the expected core-only staging? If so, there is nothing to do
# (idempotency). Any difference -- empty, a stale hash, or an earlier copy-up's TPDM package -- is
# logged by name, and the caller restages from scratch.
# ------------------------------------------------------------------------------------------------

dest_matches_expected() {
    if [ ! -f "$DEST/bootstrap-api-schema-manifest.json" ]; then
        log "$STEP_CHECK" "no manifest at $DEST/bootstrap-api-schema-manifest.json"
        return 1
    fi
    _dm_actual=$(jq -Sc . "$DEST/bootstrap-api-schema-manifest.json" 2>/dev/null) || {
        log "$STEP_CHECK" "existing manifest is not valid JSON"
        return 1
    }
    _dm_expected=$(expected_manifest)
    if [ "$_dm_actual" != "$_dm_expected" ]; then
        log "$STEP_CHECK" "existing manifest does not match the expected core-only ed-fi layout"
        return 1
    fi

    if [ ! -f "$DEST/JsonSchemaForApiSchema.json" ]; then
        log "$STEP_CHECK" "JsonSchemaForApiSchema.json missing"
        return 1
    fi
    if [ ! -f "$DEST/$PKG_REL/discovery-spec.json" ]; then
        log "$STEP_CHECK" "$PKG_REL/discovery-spec.json missing"
        return 1
    fi
    if [ ! -d "$DEST/$PKG_REL/xsd" ]; then
        log "$STEP_CHECK" "$PKG_REL/xsd is missing"
        return 1
    fi
    set -- "$DEST/$PKG_REL/xsd"/*.xsd
    if [ ! -e "$1" ]; then
        log "$STEP_CHECK" "$PKG_REL/xsd contains no .xsd files"
        return 1
    fi
    if [ ! -f "$DEST/$PKG_REL/ApiSchema.json" ]; then
        log "$STEP_CHECK" "$PKG_REL/ApiSchema.json missing"
        return 1
    fi
    _dm_hash=$(sha256_of "$DEST/$PKG_REL/ApiSchema.json") || {
        log "$STEP_CHECK" "could not hash the existing $PKG_REL/ApiSchema.json"
        return 1
    }
    if [ "$_dm_hash" != "$API_SCHEMA_SHA256" ]; then
        log "$STEP_CHECK" "existing ApiSchema.json hash $_dm_hash does not match the pin $API_SCHEMA_SHA256"
        return 1
    fi

    # No package other than the core one -- catches an earlier copy-up's TPDM directory.
    for _dm_entry in "$DEST"/Packages/*/; do
        [ -d "$_dm_entry" ] || continue
        _dm_base=${_dm_entry%/}
        _dm_base=${_dm_base##*/}
        if [ "$_dm_base" != "$PKG_NAME" ]; then
            log "$STEP_CHECK" "unexpected package under Packages/: $_dm_base"
            return 1
        fi
    done

    return 0
}

# ------------------------------------------------------------------------------------------------
# Step c: clear $DEST (children only -- the mount point itself is left in place), including
# dotfiles, so a restage never mixes old and new content.
# ------------------------------------------------------------------------------------------------

clear_dest() {
    log "$STEP_STAGE" "clearing $DEST"
    find "$DEST" -mindepth 1 -exec rm -rf {} +
}

# ------------------------------------------------------------------------------------------------
# Step d: verify the source (the DMS image's own /app/ApiSchema) before touching $DEST at all, so a
# tampered or unexpected image is caught without first destroying whatever was already staged.
# ------------------------------------------------------------------------------------------------

verify_source() {
    for _vs_file in JsonSchemaForApiSchema.json "$PKG_REL/ApiSchema.json" "$PKG_REL/discovery-spec.json"; do
        [ -f "$SRC/$_vs_file" ] || die "$STEP_VERIFY" "required source file missing: $SRC/$_vs_file"
    done
    [ -d "$SRC/$PKG_REL/xsd" ] || die "$STEP_VERIFY" "required source directory missing: $SRC/$PKG_REL/xsd"
    set -- "$SRC/$PKG_REL/xsd"/*.xsd
    [ -e "$1" ] || die "$STEP_VERIFY" "$SRC/$PKG_REL/xsd contains no .xsd files"

    _vs_hash=$(sha256_of "$SRC/$PKG_REL/ApiSchema.json") \
        || die "$STEP_VERIFY" "could not hash $SRC/$PKG_REL/ApiSchema.json"
    if [ "$_vs_hash" != "$API_SCHEMA_SHA256" ]; then
        die "$STEP_VERIFY" \
            "source ApiSchema.json SHA-256 $_vs_hash does not match the pinned API_SCHEMA_SHA256" \
            "($API_SCHEMA_SHA256) -- refusing to stage a tampered or unexpected DMS image"
    fi
    log "$STEP_VERIFY" "source ApiSchema.json SHA-256 verified against the pin"
}

# ------------------------------------------------------------------------------------------------
# Step e: copy the four required files/dirs, plus the optional package-manifest.json, then write
# the core-only manifest.
# ------------------------------------------------------------------------------------------------

stage() {
    mkdir -p "$DEST/$PKG_REL/xsd"
    cp "$SRC/JsonSchemaForApiSchema.json" "$DEST/JsonSchemaForApiSchema.json"
    cp "$SRC/$PKG_REL/ApiSchema.json" "$DEST/$PKG_REL/ApiSchema.json"
    cp "$SRC/$PKG_REL/discovery-spec.json" "$DEST/$PKG_REL/discovery-spec.json"
    if [ -f "$SRC/$PKG_REL/package-manifest.json" ]; then
        cp "$SRC/$PKG_REL/package-manifest.json" "$DEST/$PKG_REL/package-manifest.json"
    fi
    cp -R "$SRC/$PKG_REL/xsd/." "$DEST/$PKG_REL/xsd/"
    expected_manifest >"$DEST/bootstrap-api-schema-manifest.json"
    log "$STEP_STAGE" "staged $PKG_NAME from $SRC to $DEST"
}

# ------------------------------------------------------------------------------------------------
# Main: skip if already correct; otherwise verify the source, wipe $DEST, restage, and re-verify.
# ------------------------------------------------------------------------------------------------

if dest_matches_expected; then
    log "$STEP_DONE" "destination already holds the expected core-only ed-fi staging; nothing to do"
else
    verify_source
    clear_dest
    stage
    dest_matches_expected || die "$STEP_DONE" "staged content still doesn't match the expected layout"
    # DMS runs as a non-root user; a fresh volume mounted here is root-owned (see the header comment).
    chmod -R a+rX "$DEST"
    log "$STEP_DONE" "restaged and verified"
fi
