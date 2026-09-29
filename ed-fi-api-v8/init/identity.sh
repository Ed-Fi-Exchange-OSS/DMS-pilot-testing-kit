#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# init-identity (Task 3): seeds the OpenIddict signing key and the three CMS system clients that CMS
# needs before it will issue tokens, then proves the result with a real client-credentials request.
# Runs once per `up`, after CMS is healthy (compose.init.yml), and is safe to run again: every step
# checks the database first and changes nothing that is already correct.
#
# Ported from the PowerShell recipe in dms-compose/setup-openiddict.ps1 and OpenIddict-Crypto.psm1,
# proven against a real stack in tasks/spike-notes.md Q2. This script uses only sh, openssl, and
# psql (the tools image's /bin/sh is dash), because .NET is not available at container run time.
#
# Decision 9 in tasks/plan.md: .env is the source of truth for the three client secrets. On every
# run this script re-derives each stored hash from the current .env value and updates it if it no
# longer matches, so a secret rotated in .env takes effect on the next `up` with no manual step.

set -eu

# shellcheck disable=SC1007  # CDPATH= intentionally empty: stops `cd` resolving against CDPATH
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=./lib.sh
. "$SCRIPT_DIR/lib.sh"

STEP_ENV=validate-env
STEP_WAIT=wait-for-cms
STEP_KEY=signing-key
STEP_CHECK=self-check

# A private scratch directory for key material and hash intermediates. Never reused across runs,
# and removed on exit (success or failure) so no secret-derived byte ever survives the container.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/init-identity.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

require_env "$STEP_ENV" \
    CMS_SERVICE_CLIENT_SECRET CMS_READONLY_CLIENT_SECRET CMS_ADMIN_CLIENT_SECRET \
    CMS_IDENTITY_ENCRYPTION_KEY HASH_ITERATIONS \
    POSTGRES_DB_NAME POSTGRES_PASSWORD CONFIG_BASE_URL

# Task 18 (FR-CLAIM-14): the role PilotKitAdmin needs to call DMS's claim-set reload endpoint.
# Defaulted here (not required-env) so this script still runs standalone against a stub.
DMS_CLAIMSET_RELOAD_ROLE="${DMS_CLAIMSET_RELOAD_ROLE:-dms-management-operator}"

export PGHOST=db
export PGUSER=postgres
export PGDATABASE="$POSTGRES_DB_NAME"
export PGPASSWORD="$POSTGRES_PASSWORD"

# ------------------------------------------------------------------------------------------------
# Step a: validate every secret before touching the database. 32-128 characters, and at least one
# lowercase letter, one uppercase letter, one digit, and one special character from
# !@#$%^&*()-_=+[]{}:;,.? -- the same rule as upstream Test-ClientSecretComplexity. The value never
# appears in a log line, including on failure.
# ------------------------------------------------------------------------------------------------

# The special-character class below relies on two POSIX bracket-expression placement rules: a
# literal "]" must come first (right after the opening "["), and a literal "-" must come last
# (right before the closing "]"). Both are true here, so none of !@#$%^&*()_=+[]{}:;,.?- is
# mistaken for a range or for the class terminator.
_special_class='[]!@#$%^&*()_=+[{}:;,.?-]'

validate_secret() {
    _vs_name="$1"
    eval "_vs_value=\${${_vs_name}}"
    # shellcheck disable=SC2154  # _vs_value is assigned above via eval; shellcheck can't see it
    _vs_len=${#_vs_value}
    if [ "$_vs_len" -lt 32 ] || [ "$_vs_len" -gt 128 ]; then
        die "$STEP_ENV" "$_vs_name must be 32-128 characters long (got $_vs_len)"
    fi
    printf '%s' "$_vs_value" | grep -q '[a-z]' \
        || die "$STEP_ENV" "$_vs_name must contain at least one lowercase letter"
    printf '%s' "$_vs_value" | grep -q '[A-Z]' \
        || die "$STEP_ENV" "$_vs_name must contain at least one uppercase letter"
    printf '%s' "$_vs_value" | grep -q '[0-9]' \
        || die "$STEP_ENV" "$_vs_name must contain at least one digit"
    printf '%s' "$_vs_value" | grep -q "$_special_class" \
        || die "$STEP_ENV" "$_vs_name must contain at least one special character" \
               "from !@#\$%^&*()-_=+[]{}:;,.?"
}

for _var in CMS_SERVICE_CLIENT_SECRET CMS_READONLY_CLIENT_SECRET CMS_ADMIN_CLIENT_SECRET; do
    validate_secret "$_var"
done
unset _var

# The identity encryption key is a base64 key, not a client secret: a valid one can lack special
# characters, so only its length is checked here.
if [ "${#CMS_IDENTITY_ENCRYPTION_KEY}" -lt 32 ]; then
    die "$STEP_ENV" "CMS_IDENTITY_ENCRYPTION_KEY must be at least 32 characters long"
fi
log "$STEP_ENV" "secrets are valid"

# DMS's EndpointRequiredRole grammar (Configuration/EndpointRequiredRole.cs): 1-256 characters, no
# control characters, and none of space , ; " ' [ ] { }. A value that fails this leaves DMS's claim-
# set reload endpoint silently unmapped (DMS logs a warning; nothing here would otherwise notice).
_role_len=${#DMS_CLAIMSET_RELOAD_ROLE}
if [ "$_role_len" -eq 0 ] || [ "$_role_len" -gt 256 ]; then
    die "$STEP_ENV" "DMS_CLAIMSET_RELOAD_ROLE must be 1-256 characters long (got $_role_len)"
fi
case "$DMS_CLAIMSET_RELOAD_ROLE" in
    *[\ ,\;\"\'\[\]\{\}]*)
        die "$STEP_ENV" \
            "DMS_CLAIMSET_RELOAD_ROLE must not contain spaces, commas, semicolons, quotes, or [ ] { }"
        ;;
esac
unset _role_len

# ------------------------------------------------------------------------------------------------
# Step b: wait, bounded, for CMS to have created its own tables. CMS's database deploy creates
# dmscs.OpenIddictApplication, dmscs.OpenIddictKey (and the rest of the dmscs schema) and the
# pgcrypto extension; this service only runs after `config` is already healthy (compose.init.yml),
# so this loop is a short safeguard, not the primary wait.
#
# Table existence and row existence must stay two separate queries. A single query that combines
# to_regclass(...) IS NOT NULL with EXISTS (SELECT ... FROM dmscs."OpenIddictKey") fails to *plan*,
# not just to match, when the table is absent -- the planner resolves every FROM-clause relation
# before evaluating AND short-circuiting, so it errors instead of returning false (spike-notes Q2).
# ------------------------------------------------------------------------------------------------

wait_for_cms_tables() {
    _wait_attempts=0
    _wait_max_attempts=30
    _wait_interval_seconds=2
    while :; do
        _wait_result=$(kit_psql -f - <<'SQL'
SELECT (to_regclass('dmscs."OpenIddictApplication"') IS NOT NULL
        AND to_regclass('dmscs."OpenIddictKey"') IS NOT NULL);
SQL
)
        if [ "$_wait_result" = "t" ]; then
            log "$STEP_WAIT" "CMS OpenIddict tables present"
            return 0
        fi
        _wait_attempts=$((_wait_attempts + 1))
        if [ "$_wait_attempts" -ge "$_wait_max_attempts" ]; then
            _wait_seconds=$((_wait_max_attempts * _wait_interval_seconds))
            die "$STEP_WAIT" \
                "dmscs.OpenIddictApplication/OpenIddictKey still absent after ${_wait_seconds}s," \
                "is config healthy?"
        fi
        sleep "$_wait_interval_seconds"
    done
}

wait_for_cms_tables

# ------------------------------------------------------------------------------------------------
# Step c: the OpenIddict signing key, if no active row exists yet.
#
# `openssl genpkey` (no -outform DER) already writes PKCS#8, but converting straight through a pipe
# would hide a genpkey failure: dash has no `pipefail`, so only the last command's exit status would
# be seen. Each stage therefore writes to a file and is checked before the next runs.
# ------------------------------------------------------------------------------------------------

# hash_with_salt <secret> <salt-hex> <salt-file> -> base64 secret hash on stdout (ASP.NET Identity
# v3 format: 0x01, int32 LE 16, the 16-byte salt, then a 32-byte PBKDF2-HMAC-SHA256 subkey).
# HASH_ITERATIONS must equal IdentitySettings__HashingIterations in compose.core.yml (see the
# comment there); a mismatch produces a hash CMS's own hasher would never have produced, and every
# token request for that client fails.
hash_with_salt() {
    _hws_secret="$1"
    _hws_salt_hex="$2"
    _hws_salt_file="$3"
    _hws_subkey_file=$(mktemp "$WORK_DIR/subkey.XXXXXX")
    if ! openssl kdf -binary -keylen 32 -kdfopt digest:SHA256 \
        -kdfopt "pass:$_hws_secret" -kdfopt "hexsalt:$_hws_salt_hex" \
        -kdfopt "iter:$HASH_ITERATIONS" PBKDF2 >"$_hws_subkey_file" 2>/dev/null
    then
        rm -f "$_hws_subkey_file"
        return 1
    fi
    { printf '\001\020\000\000\000'; cat "$_hws_salt_file"; cat "$_hws_subkey_file"; } | base64 -w0
    rm -f "$_hws_subkey_file"
}

# compute_secret_hash <secret> -> base64 secret hash on stdout, using a freshly generated salt.
compute_secret_hash() {
    _cs_secret="$1"
    _cs_salt_file=$(mktemp "$WORK_DIR/salt.XXXXXX")
    openssl rand -out "$_cs_salt_file" 16
    _cs_salt_hex=$(od -An -tx1 "$_cs_salt_file" | tr -d ' \n')
    hash_with_salt "$_cs_secret" "$_cs_salt_hex" "$_cs_salt_file"
    _cs_rc=$?
    rm -f "$_cs_salt_file"
    return $_cs_rc
}

ensure_signing_key() {
    _key_active=$(kit_psql -f - <<'SQL'
SELECT EXISTS (SELECT 1 FROM dmscs."OpenIddictKey" WHERE "IsActive" = TRUE);
SQL
)
    if [ "$_key_active" = "t" ]; then
        log "$STEP_KEY" "active key present, skipping"
        return 0
    fi

    _key_priv_pem=$(mktemp "$WORK_DIR/key-priv.XXXXXX.pem")
    _key_priv_der=$(mktemp "$WORK_DIR/key-priv.XXXXXX.der")
    _key_pub_der=$(mktemp "$WORK_DIR/key-pub.XXXXXX.der")

    # -quiet: without it, openssl writes a "....+++++" progress meter to stderr that would otherwise
    # land in `docker compose logs init-identity` on every run.
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -quiet -out "$_key_priv_pem" \
        || die "$STEP_KEY" "openssl genpkey failed"
    # Plain `genpkey -outform DER` would still be PKCS#1; the -topk8 step below is what makes it
    # PKCS#8, which is the only format CMS's key loader accepts (spike-notes Q2: PKCS#1 makes every
    # token request fail with a 500, "ASN1 corrupted data ... 'Universal' class value '2' ... '16'").
    openssl pkcs8 -topk8 -nocrypt -in "$_key_priv_pem" -outform DER -out "$_key_priv_der" \
        || die "$STEP_KEY" "openssl pkcs8 (PKCS#1 -> PKCS#8) conversion failed"
    openssl pkey -inform DER -in "$_key_priv_der" -pubout -outform DER -out "$_key_pub_der" \
        || die "$STEP_KEY" "failed to derive the SPKI public key"

    _key_priv_b64=$(base64 -w0 "$_key_priv_der")
    _key_pub_b64=$(base64 -w0 "$_key_pub_der")
    rm -f "$_key_priv_pem" "$_key_priv_der" "$_key_pub_der"

    # KeyId: base64 of a UTF-8 GUID string, matching upstream New-OpenIddictKeyInsertSql. Falls back
    # to a hand-assembled UUID string if /proc is unavailable (openssl has no UUID generator).
    if [ -r /proc/sys/kernel/random/uuid ]; then
        _key_guid=$(cat /proc/sys/kernel/random/uuid)
    else
        _key_guid=$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    fi
    _key_kid=$(printf '%s' "$_key_guid" | base64 -w0)

    kit_psql -v kid="$_key_kid" -v pub="$_key_pub_b64" -v priv="$_key_priv_b64" \
        -v enc="$CMS_IDENTITY_ENCRYPTION_KEY" -f - <<'SQL'
INSERT INTO dmscs."OpenIddictKey" ("KeyId", "PublicKey", "PrivateKey", "IsActive")
VALUES (:'kid', decode(:'pub', 'base64'), pgp_sym_encrypt(:'priv', :'enc'), TRUE);
SQL
    log "$STEP_KEY" "inserted a new active signing key"
}

ensure_signing_key

# ------------------------------------------------------------------------------------------------
# Step d/e/f: the three CMS system clients. Each is created if missing, and reconciled if present:
# the stored ClientSecret is decoded and compared against a hash re-derived from .env with the
# stored salt (upstream ASP.NET Identity v3 layout: 0x01, int32 LE 16, 16-byte salt, 32-byte
# subkey -- 53 bytes total). A mismatch or a malformed stored value gets a fresh hash; a match is
# left untouched. Roles, scope, permissions and the namespacePrefixes mapper are (re)asserted on
# every run regardless, so an existing client converges to the same shape a new one gets.
# ------------------------------------------------------------------------------------------------

# reconcile_secret_hash <existing-base64> <secret> -> prints the hash to store on stdout.
# Returns 0 if the existing value already matches (nothing to change), 1 otherwise (including when
# the existing value is malformed), so callers can log which happened without a second comparison.
reconcile_secret_hash() {
    _rc_existing_b64="$1"
    _rc_secret="$2"
    _rc_raw_file=$(mktemp "$WORK_DIR/existing.XXXXXX")

    if ! printf '%s' "$_rc_existing_b64" | base64 -d >"$_rc_raw_file" 2>/dev/null; then
        rm -f "$_rc_raw_file"
        compute_secret_hash "$_rc_secret"
        return 1
    fi

    _rc_size=$(wc -c <"$_rc_raw_file")
    _rc_header=$(od -An -tx1 -N5 "$_rc_raw_file" | tr -d ' \n')
    if [ "$_rc_size" -ne 53 ] || [ "$_rc_header" != "0110000000" ]; then
        rm -f "$_rc_raw_file"
        compute_secret_hash "$_rc_secret"
        return 1
    fi

    # The salt occupies bytes 6-21 (1-indexed): 5 header bytes, then 16 salt bytes, then the
    # 32-byte subkey.
    _rc_salt_file=$(mktemp "$WORK_DIR/existing-salt.XXXXXX")
    tail -c +6 "$_rc_raw_file" | head -c 16 >"$_rc_salt_file"
    _rc_salt_hex=$(od -An -tx1 "$_rc_salt_file" | tr -d ' \n')
    _rc_recomputed=$(hash_with_salt "$_rc_secret" "$_rc_salt_hex" "$_rc_salt_file")
    rm -f "$_rc_raw_file" "$_rc_salt_file"

    if [ "$_rc_recomputed" = "$_rc_existing_b64" ]; then
        printf '%s' "$_rc_existing_b64"
        return 0
    fi
    printf '%s' "$_rc_recomputed"
    return 1
}

# ensure_client <client-id> <display-name> <secret-env-var> <scope>
ensure_client() {
    _ec_client_id="$1"
    _ec_display_name="$2"
    _ec_secret_var="$3"
    _ec_scope="$4"
    eval "_ec_secret=\${${_ec_secret_var}}"

    _ec_existing_hash=$(kit_psql -v cid="$_ec_client_id" -f - <<'SQL'
SELECT "ClientSecret" FROM dmscs."OpenIddictApplication" WHERE "ClientId" = :'cid';
SQL
)

    if [ -z "$_ec_existing_hash" ]; then
        # shellcheck disable=SC2154  # _ec_secret is assigned above via eval; shellcheck can't see it
        _ec_hash=$(compute_secret_hash "$_ec_secret") || _ec_hash=
        log "$_ec_client_id" "creating client"
    elif _ec_hash=$(reconcile_secret_hash "$_ec_existing_hash" "$_ec_secret"); then
        log "$_ec_client_id" "unchanged"
    else
        log "$_ec_client_id" "updated secret for $_ec_client_id"
    fi

    # A failed openssl call inside the command substitutions above leaves an empty or short value;
    # never store that as the client secret. A valid hash is 53 bytes, so 72 base64 characters.
    if [ "${#_ec_hash}" -ne 72 ]; then
        die "$_ec_client_id" "failed to compute the client secret hash"
    fi

    # One transaction per client. The initial INSERT is skipped (ON CONFLICT ... DO NOTHING) when
    # the client already exists; the UPDATEs after it then apply to every client on every run, which
    # is what makes an already-existing client converge to the same roles/scope/permissions/mapper a
    # brand-new one gets, without a second code path for "existing" versus "new" (spike-notes Q2,
    # plan.md decision 9).
    kit_psql -v cid="$_ec_client_id" -v name="$_ec_display_name" -v hash="$_ec_hash" -v scope="$_ec_scope" \
        -f - <<'SQL'
BEGIN;

INSERT INTO dmscs."OpenIddictApplication"
    ("Id", "ClientId", "ClientSecret", "DisplayName", "Type", "Permissions", "ProtocolMappers")
VALUES (
    gen_random_uuid(), :'cid', :'hash', :'name', 'confidential', ARRAY[:'scope']::varchar[],
    jsonb_build_array(jsonb_build_object(
        'claim.name', 'namespacePrefixes', 'claim.value', 'http://ed-fi.org', 'jsonType.label', 'String'))
)
ON CONFLICT ON CONSTRAINT "UX_OpenIddictApplication_ClientId" DO NOTHING;

UPDATE dmscs."OpenIddictApplication"
SET "ClientSecret" = :'hash'
WHERE "ClientId" = :'cid';

UPDATE dmscs."OpenIddictApplication"
SET "Permissions" = ARRAY[:'scope']::varchar[]
WHERE "ClientId" = :'cid';

UPDATE dmscs."OpenIddictApplication"
SET "ProtocolMappers" = COALESCE("ProtocolMappers", '[]'::jsonb) ||
    jsonb_build_array(jsonb_build_object(
        'claim.name', 'namespacePrefixes', 'claim.value', 'http://ed-fi.org', 'jsonType.label', 'String'))
WHERE "ClientId" = :'cid'
  AND NOT (COALESCE("ProtocolMappers", '[]'::jsonb) @> jsonb_build_array(jsonb_build_object(
        'claim.name', 'namespacePrefixes', 'claim.value', 'http://ed-fi.org', 'jsonType.label', 'String')));

INSERT INTO dmscs."OpenIddictRole" ("Id", "Name")
VALUES (gen_random_uuid(), 'dms-client'), (gen_random_uuid(), 'cms-client')
ON CONFLICT ON CONSTRAINT "UX_OpenIddictRole_Name" DO NOTHING;

INSERT INTO dmscs."OpenIddictClientRole" ("ClientId", "RoleId")
SELECT a."Id", r."Id" FROM dmscs."OpenIddictApplication" a, dmscs."OpenIddictRole" r
WHERE a."ClientId" = :'cid' AND r."Name" IN ('dms-client', 'cms-client')
ON CONFLICT ON CONSTRAINT "PK_OpenIddictClientRole" DO NOTHING;

INSERT INTO dmscs."OpenIddictScope" ("Id", "Name", "Description")
VALUES (gen_random_uuid(), :'scope', :'scope')
ON CONFLICT ON CONSTRAINT "UX_OpenIddictScope_Name" DO NOTHING;

INSERT INTO dmscs."OpenIddictApplicationScope" ("ApplicationId", "ScopeId")
SELECT a."Id", s."Id" FROM dmscs."OpenIddictApplication" a, dmscs."OpenIddictScope" s
WHERE a."ClientId" = :'cid' AND s."Name" = :'scope'
ON CONFLICT ON CONSTRAINT "PK_OpenIddictApplicationScope" DO NOTHING;

COMMIT;
SQL
}

ensure_client DmsConfigurationService "DMS Configuration Service" \
    CMS_SERVICE_CLIENT_SECRET edfi_admin_api/full_access
ensure_client CMSReadOnlyAccess "CMS ReadOnly Access" \
    CMS_READONLY_CLIENT_SECRET edfi_admin_api/readonly_access
ensure_client PilotKitAdmin "Pilot Kit Admin" \
    CMS_ADMIN_CLIENT_SECRET edfi_admin_api/full_access

# ------------------------------------------------------------------------------------------------
# Step g: grant PilotKitAdmin -- and only PilotKitAdmin -- the role that DMS's claim-set reload
# endpoint requires (Task 18, FR-CLAIM-14). A participant integration credential (a CMS /v3/
# applications vendor client) only ever gets IdentitySettings__ClientRole (dms-client), never this
# role, so it cannot call the endpoint. Idempotent, same ON CONFLICT pattern as the dms-client/
# cms-client grant inside ensure_client above.
# ------------------------------------------------------------------------------------------------

ensure_extra_role() {
    _eer_client_id="$1"
    _eer_role="$2"
    kit_psql -v cid="$_eer_client_id" -v role="$_eer_role" -f - <<'SQL'
BEGIN;

INSERT INTO dmscs."OpenIddictRole" ("Id", "Name")
VALUES (gen_random_uuid(), :'role')
ON CONFLICT ON CONSTRAINT "UX_OpenIddictRole_Name" DO NOTHING;

INSERT INTO dmscs."OpenIddictClientRole" ("ClientId", "RoleId")
SELECT a."Id", r."Id" FROM dmscs."OpenIddictApplication" a, dmscs."OpenIddictRole" r
WHERE a."ClientId" = :'cid' AND r."Name" = :'role'
ON CONFLICT ON CONSTRAINT "PK_OpenIddictClientRole" DO NOTHING;

COMMIT;
SQL
    log "$_eer_client_id" "has role '$_eer_role'"
}

ensure_extra_role PilotKitAdmin "$DMS_CLAIMSET_RELOAD_ROLE"

# ------------------------------------------------------------------------------------------------
# Step h: self-check. Requests a token for PilotKitAdmin and confirms CMS actually accepts the
# signing key and the hash this script just wrote.
# ------------------------------------------------------------------------------------------------

self_check() {
    cms_token "$STEP_CHECK" PilotKitAdmin "$CMS_ADMIN_CLIENT_SECRET" edfi_admin_api/full_access >/dev/null
    log "$STEP_CHECK" "PilotKitAdmin token request succeeded"
}

self_check

log identity "done"
