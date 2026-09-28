# Phase 0 spike notes (Task 1)

Run on 2026-09-28 on a Windows 11 host with Docker Desktop 29.7.2 (WSL2, `x86_64`/`amd64`), from
`ed-fi-api-v8/` on branch `dms-compose`, as Compose project `edfi-spike` (ports 9443/9080/5445,
`PUBLIC_ORIGIN=https://localhost:9443`). The original `.env` was backed up and restored. All
throwaway scripts lived outside the repo; nothing in `ed-fi-api-v8/` was changed. Keys and secrets
below are `<redacted>`.

Shorthand used below:

- `run …` = `docker compose run --rm -T tools …` (the kit tools image), with the spike scripts
  bind-mounted at `/spike` and a scratch directory at `/w`.
- `cms METHOD PATH [body]` = a `curl` from the tools container to `http://config:8081`, with a
  `PilotKitAdmin` token (`edfi_admin_api/full_access`).
- `dms <cred> METHOD PATH [body]` = a `curl` from the tools container to `http://dms:8080/api`
  with a token for that credential.
- `spike-tools:local` = a throwaway image `FROM edfi-pilot-tools:local` adding `unzip` and an
  `app`-owned `/app/ApiSchema` (the two tools-image gaps found in Q1/Q3). Used only for staging.

**PILOT-RELEVANT BLOCKERS FOUND** (details in the sections):

1. `compose.ingress.yml` Swagger UI serves an **empty `index.html`** (YAML folded-scalar bug). Q10.
2. An empty `api-schema` volume is **auto-filled by Docker with the image's core + TPDM schema** the
   first time DMS mounts it, silently violating "core only". Q3.
3. DMS also needs `JsonSchemaForApiSchema.json` and `bootstrap-api-schema-manifest.json` in the
   volume; neither is in the nupkg. Q3.
4. The `SeedLoader` application needs **education organization IDs and the `uri://gbisd.edu`
   namespace** for the populated template; without them 96% of sample records 403. Q9.
5. The tools image can't write the `api-schema` volume (non-root) and has no `unzip`. Q1/Q3.

---

## Q1. Tools image

**Answer:** Builds and both tools run on `dotnet/runtime:10.0.12-noble`. Two defects: BulkLoadClient's
log4net file appender fails for the non-root user, and there is no `unzip`.

| Check | Result |
| --- | --- |
| `docker compose --profile tools build tools` | Success, 32 s (base images already cached). Build-time smoke check printed `8.0.1-alpha.0.164+0abbaf2c…`, `EdFi.BulkLoadClient.Console 1.0.0-7.3.20162+e907fe57…`, `psql (PostgreSQL) 16.15`, `jq-1.7` |
| `run api-schema-tools --version` | `8.0.1-alpha.0.164+0abbaf2c2178d2ff0379b4cb3214df33df4da744` |
| `run bulkloadclient --version` | `EdFi.BulkLoadClient.Console 1.0.0-7.3.20162+e907fe5746468a45e4cd7e7542d2912690cac7d1`, preceded by `log4net:ERROR RollingFileAppender: INTERNAL ERROR. Append is False but OutputFile [/opt/bulkloadclient/logfile.txt] already exists.` |
| Image size | `docker image ls`: 598 MB on disk, 158 MB content (compressed); `inspect .Size` = 157,692,143 bytes |
| Host architecture | `amd64` (arm64 not tested) |

Evidence and findings:

- **log4net path.** `log4net.config` uses `<file value="logfile.txt" />`, which resolves against
  the app base directory, not the working directory. The build-time `bulkloadclient --version` (run
  as root) creates `/opt/bulkloadclient/logfile.txt` owned by `root`, so every run as UID 1654 logs
  a log4net error per log event: **21,815 error lines** during the 3,303-descriptor load. Loading
  still succeeds (console appender works). The tools README's claim that it writes to the current
  directory is wrong.
- **No `unzip`, `perl`, `python3`, or `xxd`** in the image (`command -v …` found none). A `.nupkg`
  and the Data Standard zip can't be extracted in-container.
- The `/opt/tools/api-schema-tools` shim finds the runtime (the README's open item is resolved).
- Git Bash on Windows rewrites `/app/...` arguments into `C:/…/Git/app/...` unless
  `MSYS_NO_PATHCONV=1` is set. This matters for the host `.sh` wrappers in Task 12.

**Impact:** Task 4/8: fix the Dockerfile (see Recommended changes). Task 12: set
`MSYS_NO_PATHCONV=1` in Bash wrappers, or pass only container-side paths through env vars.

---

## Q2. Identity seeding

**Answer:** It works with `openssl` + `psql` only. No .NET is needed. The CMS database deploy
already creates `dmscs.OpenIddictKey` and the `pgcrypto` extension, but not a key row. CMS reads the
key **lazily on the first token request**, so the key can be inserted before *or* after CMS starts
without a restart. Both orders were proven on clean volumes.

### Minimal sequence

Run from the tools container as `postgres`
(`PGHOST=db PGUSER=postgres PGDATABASE=edfi_datamanagementservice`); values pass as psql variables
(`-v name=value`, referenced as `:'name'`), so no SQL is built by string concatenation.

**Key** (idempotent; skip if an active key exists; check table existence and row existence as two
separate queries, because `to_regclass(...) IS NOT NULL AND EXISTS (SELECT … FROM dmscs."OpenIddictKey")`
fails to plan when the table is absent, which the spike hit on its first clean run):

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  | openssl pkcs8 -topk8 -nocrypt -outform DER -out k.der    # PKCS#8 DER
priv=$(base64 -w0 k.der)
pub=$(openssl pkey -inform DER -in k.der -pubout -outform DER | base64 -w0)   # SPKI DER
kid=$(cat /proc/sys/kernel/random/uuid | tr -d '\n' | base64 -w0)            # base64(UTF-8 GUID), as upstream
```

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;          -- only needed if run before CMS
CREATE SCHEMA IF NOT EXISTS dmscs;                -- ditto
CREATE TABLE IF NOT EXISTS dmscs."OpenIddictKey" (...same DDL as setup-openiddict.ps1 -InitDb...);
INSERT INTO dmscs."OpenIddictKey" ("KeyId","PublicKey","PrivateKey","IsActive")
VALUES (:'kid', decode(:'pub','base64'), pgp_sym_encrypt(:'priv', :'enc'), TRUE);   -- enc = CMS_IDENTITY_ENCRYPTION_KEY
```

**Gotcha:** `openssl genpkey -outform DER` writes **PKCS#1**, not PKCS#8. CMS then fails every token
request with HTTP 500, logging `Failed to load private key from database … ASN1 corrupted data … tagged
with 'Universal' class value '2', but it should have been 'Universal' class value '16'`. Piping
through `openssl pkcs8 -topk8 -nocrypt` fixes it (`openssl asn1parse` shows the `rsaEncryption`
AlgorithmIdentifier).

**Clients** (after CMS has created its tables; one transaction per client; all `ON CONFLICT … DO
NOTHING`):

```sql
INSERT INTO dmscs."OpenIddictApplication" ("Id","ClientId","ClientSecret","DisplayName","Type","Permissions","ProtocolMappers")
VALUES (gen_random_uuid(), :'cid', :'hash', :'name', 'confidential', ARRAY[:'scope']::varchar[],
        jsonb_build_array(jsonb_build_object('claim.name','namespacePrefixes','claim.value','http://ed-fi.org','jsonType.label','String')))
ON CONFLICT ON CONSTRAINT "UX_OpenIddictApplication_ClientId" DO NOTHING;
INSERT INTO dmscs."OpenIddictRole" ("Id","Name") VALUES (gen_random_uuid(),'dms-client'),(gen_random_uuid(),'cms-client')
ON CONFLICT ON CONSTRAINT "UX_OpenIddictRole_Name" DO NOTHING;
INSERT INTO dmscs."OpenIddictScope" ("Id","Name","Description") VALUES (gen_random_uuid(), :'scope', :'scope')
ON CONFLICT ON CONSTRAINT "UX_OpenIddictScope_Name" DO NOTHING;
INSERT INTO dmscs."OpenIddictClientRole" ("ClientId","RoleId")
  SELECT a."Id", r."Id" FROM dmscs."OpenIddictApplication" a, dmscs."OpenIddictRole" r
  WHERE a."ClientId" = :'cid' AND r."Name" IN ('dms-client','cms-client')
ON CONFLICT ON CONSTRAINT "PK_OpenIddictClientRole" DO NOTHING;
INSERT INTO dmscs."OpenIddictApplicationScope" ("ApplicationId","ScopeId")
  SELECT a."Id", s."Id" FROM dmscs."OpenIddictApplication" a, dmscs."OpenIddictScope" s
  WHERE a."ClientId" = :'cid' AND s."Name" = :'scope'
ON CONFLICT ON CONSTRAINT "PK_OpenIddictApplicationScope" DO NOTHING;
```

| Client | Secret from `.env` | Scope |
| --- | --- | --- |
| `DmsConfigurationService` | `CMS_SERVICE_CLIENT_SECRET` | `edfi_admin_api/full_access` |
| `CMSReadOnlyAccess` | `CMS_READONLY_CLIENT_SECRET` | `edfi_admin_api/readonly_access` |
| `PilotKitAdmin` (spike name for the admin client) | **new** `CMS_ADMIN_CLIENT_SECRET` | `edfi_admin_api/full_access` |

Both roles go on every client, as upstream does. `setup-openiddict.ps1` also seeds a third
upstream client, `CMSAuthMetadataReadOnlyAccess` (`edfi_admin_api/authMetadata_readonly_access`);
the kit doesn't need it.

### Secret hash (`New-AspNetPasswordHash`)

Format: `0x01 | int32 LE 16 | 16-byte salt | PBKDF2-HMAC-SHA256(secret, salt, 210000, 32)`, then base64
(53 bytes, 72 chars). With OpenSSL 3.0.13 (in the image):

```sh
salt=$(openssl rand -hex 16)
sub=$(openssl kdf -keylen 32 -kdfopt digest:SHA256 -kdfopt "pass:$secret" -kdfopt "hexsalt:$salt" \
      -kdfopt iter:210000 PBKDF2 | tr -d ':\n')
printf '0110000000%s%s' "$salt" "$sub" | hex2bin | base64 -w0   # hex2bin: POSIX printf '\ooo' loop (no xxd)
```

Checked against .NET: the container's hash for a test secret was decoded on the host with
`Rfc2898DeriveBytes.Pbkdf2(…, 210000, SHA256, 32)` → `len=53 ver=1 saltLen=16 match=True`. Note the
secret is passed as a `-kdfopt pass:` argument, so it's briefly visible in the container's process
list. That's acceptable for a local kit, but `-kdfopt hexpass:` has the same exposure. Also,
`HASH_ITERATIONS` must match `IdentitySettings__HashingIterations` (210000).

### pgcrypto

Needed (`pgp_sym_encrypt`). CMS's own deploy creates it (`\dx` shows `pgcrypto 1.3` after CMS starts
on an empty DB), so a post-CMS seed needs nothing extra; a pre-CMS seed must
`CREATE EXTENSION IF NOT EXISTS pgcrypto` itself (the `postgres` superuser can).

### Proof

- `POST http://config:8081/connect/token` with `grant_type=client_credentials&client_id=PilotKitAdmin&client_secret=<redacted>&scope=edfi_admin_api/full_access`
  → `HTTP 200 {"token_type":"Bearer","expires_in":1800,…}`, key inserted **while CMS was already
  running**, no restart.
- `CMSReadOnlyAccess` token payload (decoded): `"scope":"edfi_admin_api/readonly_access"`,
  `"http://schemas.microsoft.com/ws/2008/06/identity/claims/role":["dms-client","cms-client"]`,
  `"namespacePrefixes":"http://ed-fi.org"`, `"iss":"http://config:8081"`, `"aud":"account"`.
- DMS then logged `Requesting authentication token from Configuration Service at http://config:8081/`
  and **no 401**. It moved on to the next failure (`LoadDataStores`, see Q4).
- Clean run 2, key **before** CMS: `key: inserted` → `up -d --wait config` healthy (CMS's
  `CREATE TABLE` coexists with the pre-created table), 1 key row, a second `key` run printed
  `key: active key present, skipping`, and every later token request succeeded.
- Re-running `clients` is idempotent (`ON CONFLICT DO NOTHING`); a changed secret in `.env` is **not**
  applied to an existing client. Task 3 must decide whether to update the hash on re-run.

**Impact:** Task 3: implement as one `init-identity` one-shot service after CMS is healthy (simplest:
CMS creates the table and extension, and the lazy key load removes any ordering need), or split it
before and after CMS. Add `CMS_ADMIN_CLIENT_SECRET` to `.env.example`, since the admin client needs
its own secret. The complexity rule from `setup-openiddict.ps1` (lower/upper/digit/special, 32–128)
should be validated in `sh` so a bad `.env` fails with a clear message.

---

## Q3. ApiSchema staging

**Package:** `https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/flat2/edfi.datastandard52.apischema/1.0.335/edfi.datastandard52.apischema.1.0.335.nupkg`

- SHA-256: **`b7014dc567006d2dbbf89d998bc8a9dd3bdf1f7902cfeaf27622f3e750366af1`** (907,660 bytes)
- nuspec `repository commit="71cacd813bd617681c7ef23cd4eae1e8d31b8231"`; `projectVersion` 5.2.0,
  349 resource schemas
- Contents under `contentFiles/any/any/ApiSchema/`: `ApiSchema.json` (13.2 MB), `discovery-spec.json`,
  `package-manifest.json`, `xsd/` (27 files)
- `api-schema-tools hash` → **`a0d39468ef30d3e99273065256bfffa42b799404ca5fbc09a8648f349d9217e1`**,
  matching the tools README

### Required layout

This is what the DMS image's own `run.sh` generates when `SCHEMA_PACKAGES` is set, and what the image
ships at `/app/ApiSchema`. Core-only version:

```text
/app/ApiSchema/
  JsonSchemaForApiSchema.json                 # REQUIRED; not in the nupkg; copy from the DMS image
  bootstrap-api-schema-manifest.json          # REQUIRED
  Packages/EdFi.DataStandard52.ApiSchema/
    ApiSchema.json                            # REQUIRED
    discovery-spec.json                       # needed for one endpoint (below)
    package-manifest.json                     # not read by DMS; harmless
    xsd/*.xsd                                 # needed for the XSD endpoints (below)
```

```json
{ "version": 1, "projects": [ {
    "projectName": "Ed-Fi", "projectEndpointName": "ed-fi", "isExtensionProject": false,
    "schemaPath": "Packages/EdFi.DataStandard52.ApiSchema/ApiSchema.json",
    "discoverySpecPath": "Packages/EdFi.DataStandard52.ApiSchema/discovery-spec.json",
    "xsdDirectory": "Packages/EdFi.DataStandard52.ApiSchema/xsd" } ] }
```

The manifest can be generated with one `jq` from `package-manifest.json` (as `run.sh` does). The
upstream `dms-compose/.bootstrap/ApiSchema/` uses a different, equivalent layout
(`schemas/Ed-Fi/…`, `content/Ed-Fi/…`) plus TPDM. DMS follows whatever paths the manifest names.

### What happens when a file is missing

Each case: stage, `docker compose restart dms`, probe.

| Omitted | DMS | Effect |
| --- | --- | --- |
| `JsonSchemaForApiSchema.json` | **Fatal**, restart loop | `[Core Schema] "$." - "ApiSchemaValidator failed to validate, check server configuration for JsonSchemaForApiSchema.json"` → `Fatal startup failure in phase "InitializeApiSchemas"` |
| `bootstrap-api-schema-manifest.json` | **Fatal**, restart loop; `/api` → 503 | `Required bootstrap manifest file 'bootstrap-api-schema-manifest.json' was not found in ApiSchema workspace '/app/ApiSchema'.` |
| `discovery-spec.json` | Healthy; `/api` 200 | `GET /api/metadata/specifications/discovery-spec.json` → **500** |
| `xsd/` | Healthy; `/api` 200, `/api/metadata/xsd` 200 | `GET /api/metadata/xsd/ed-fi/files` → **500** |

So all four are needed for FR-FEAT-2/3.

### Trap: Docker copy-up fills an empty volume with core + TPDM

The DMS image contains `/app/ApiSchema` (`bootstrap-api-schema-manifest.json` listing **Ed-Fi and
TPDM**, `Packages/EdFi.DataStandard52.ApiSchema`, `Packages/EdFi.DataStandard52.TPDM.ApiSchema`,
`JsonSchemaForApiSchema.json`). When an **empty** named volume is first mounted there, Docker copies
that content in, even with `:ro`. In the spike, DMS was started before staging, and afterwards the
volume held `Packages/EdFi.DataStandard52.TPDM.ApiSchema/…` (15.4 MB). If the init service ever
leaves the volume empty (skipped, failed but ignored, or DMS started first), DMS silently serves TPDM,
and its effective schema hash won't match a core-only provision.

The image's baked core `ApiSchema.json` is **byte-identical** to 1.0.335 (`sha256 1051c5c3…5aac5e73`
for both), and `discovery-spec.json` too (`f60c102f…`). So the DMS image itself is a pinned,
offline source for the core files and `JsonSchemaForApiSchema.json`.

### Permissions

A fresh named volume mounted into the tools image (no `/app/ApiSchema` in the image) is `root:root 755`;
UID 1654 gets `touch: cannot touch '/app/ApiSchema/x': Permission denied`. Adding
`RUN install -d -o 1654 -g 1654 /app/ApiSchema` to the image makes Docker initialise a new volume as
`app:app` (`drwxr-xr-x 2 app app`, `WRITE-OK`, tested with a derived image).

**Impact:** Task 4. Options, in order of preference:

1. **Stage from the DMS image** (`init-api-schema` service with `image: ${DMS_IMAGE}`,
   `entrypoint: sh`, volume mounted at `/stage`): copy `JsonSchemaForApiSchema.json` and
   `Packages/EdFi.DataStandard52.ApiSchema/` from `/app/ApiSchema`, write a core-only manifest with
   `jq` (present in the DMS image), and verify `sha256sum ApiSchema.json` against a pin. No network,
   no unzip, and the schema always matches the DMS build. Mounting at `/stage` (not `/app/ApiSchema`)
   avoids copy-up. DMS `depends_on` it with `service_completed_successfully`.
2. Download the nupkg in the tools image (needs `unzip` and the directory fix), and still copy
   `JsonSchemaForApiSchema.json` from the DMS image.

Either way, DMS must never mount the volume before it's staged, and the init step must fail if
`bootstrap-api-schema-manifest.json` lists anything but `ed-fi`. Consider `volume: {nocopy: true}`
on the DMS mount as a belt-and-braces guard (not tested).

---

## Q4. Data store registration

**Answer:**

```http
POST http://config:8081/v3/dataStores
Authorization: Bearer <admin token>
Content-Type: application/json

{ "name": "Pilot Kit", "dataStoreType": "Development", "provider": "postgresql",
  "connectionString": "host=db;port=5432;username=postgres;password=<redacted>;database=edfi_datamanagementservice;Maximum Pool Size=50;" }
```

→ `HTTP 201`, `Location: http://config:8081/v3/dataStores/1`,
`{"id":1,"status":201,"title":"New DataStore Pilot Kit has been created successfully."}`.

- **Required fields:** `name`, `dataStoreType` (non-empty free text; `{"name":"Spike DS"}` →
  `"DataStoreType":["'Data Store Type' must not be empty."]`; upstream uses `Development`), and
  `provider` (`postgresql` or `sqlserver`, lowercase: `"PostgreSQL"` → `"Provider must be 'postgresql' or
  'sqlserver'."`). `connectionString` is optional in validation, but DMS needs it.
- **Encrypted:** yes. The column is `bytea`, and `GET /v3/dataStores` returns the ciphertext
  (`"connectionString":"GVwAbvdo0AsLeOsW6Zs…"`), encrypted with `CMS_DATABASE_ENCRYPTION_KEY`. DMS
  decrypts it with `ConfigurationServiceSettings__EncryptionKey`, which compose already sets to the
  same value. Idempotency needs a `GET /v3/dataStores` + name match (there's no upsert).
- **Pool size:** in this connection string (`Maximum Pool Size=`). DMS's `DATABASE_CONNECTION_STRING_ADMIN`
  is only parsed by `run.sh` for `pg_isready`. During the resources load, `pg_stat_activity` held
  12 client connections (BulkLoadClient `-c 10`), well under 50; the ceiling itself wasn't load-tested.
- **Required before DMS will start:** a data store, yes. Without one, DMS exits in a restart loop:
  `Fatal startup failure in phase "LoadDataStores". "Unable to load data stores from Configuration
  Service. DMS cannot start without proper data store configuration."` (`No data stores were loaded
  from Configuration Service`). A data store **context** isn't needed: everything in this spike ran
  with `dataStoreContexts: []`.
- DMS reads data stores **at startup**. Register before DMS starts; the plan's order (identity →
  data store → schema → DMS) holds.

**Impact:** Task 4: `init-datastore` runs after CMS and identity, before DMS. Add a
`DMS_DB_MAX_POOL_SIZE` `.env` setting (default 50) that feeds this string. The `.env.example`
comment already says the pool is on the data store string.

---

## Q5. Schema provisioning

**Command** (from the tools container, after the volume is staged):

```sh
api-schema-tools ddl provision \
  --schema /app/ApiSchema/Packages/EdFi.DataStandard52.ApiSchema/ApiSchema.json \
  --connection-string "Host=db;Port=5432;Database=${POSTGRES_DB_NAME};Username=postgres;Password=${POSTGRES_PASSWORD}" \
  --dialect pgsql --create-database
```

First run: `Effective schema hash: a0d39468…d9217e1, resource keys: 351` → `Database already exists` →
`Executing DDL in transaction` → `DDL executed successfully` → `Provisioning complete` in **13.5 s**
wall (≈10 s of DDL), exit 0. Result: 629 tables across `auth`, `dms`, `edfi`, `tracked_changes_edfi`,
plus `dmscs` (CMS) and `public`. Empty-schema DB size: 49.4 MB (`pg_database_size`).

**After provisioning** (plus the Q3 files and a data store):

- DMS: `docker compose ps` → `dms Up (healthy)`; `up -d --wait dms` succeeded.
- `GET https://localhost:9443/api` → 200:

  ```json
  {"version":"8.0.1","applicationName":"Ed-Fi API","informationalVersion":"8.0.1-alpha.0.164",
   "dataModels":[{"name":"Ed-Fi","version":"5.2.0","informationalVersion":"The Ed-Fi Data Standard v5.2.0"}],
   "urls":{"dependencies":"https://localhost:9443/api/metadata/dependencies",
           "openApiMetadata":"https://localhost:9443/api/metadata/specifications",
           "oauth":"https://localhost:9443/api/oauth/token", "tokenInfo":"https://localhost:9443/api/oauth/token_info",
           "dataManagementApi":"https://localhost:9443/api/data", "changeQueries":"https://localhost:9443/api/changeQueries/v1/",
           "xsdMetadata":"https://localhost:9443/api/metadata/xsd"}}
  ```

  Core only (no TPDM), and `https://localhost:9443/...` URLs (forwarded headers work).
- `dms."EffectiveSchema"`: one row, `ApiSchemaFormatVersion 1.0.0`, `EffectiveSchemaHash
  a0d39468ef30d3e99273065256bfffa42b799404ca5fbc09a8648f349d9217e1`, `ResourceKeyCount 351`. That
  matches `api-schema-tools hash`, and it was identical on both clean runs.
- **Second provision:** exit 0 in 4.4 s: `Preflight ResourceKey seed validation passed`, `Preflight
  SchemaComponent seed validation passed`, `DDL executed successfully`. `EffectiveSchema.AppliedAt`
  was unchanged (`22:15:36.603074+00`) and the row count stayed 1. Effectively a no-op; it re-runs
  idempotent DDL rather than skipping, so an init script can either always run it or skip when
  `dms."EffectiveSchema"` has the expected hash (cheaper, and it detects a hash mismatch early).

**Impact:** Task 4: `init-schema` after staging; run as `postgres` (non-superuser untested, still
open). Checkpoint A reached by hand: an authenticated `GET /api/data/ed-fi/schools` returned 200.

---

## Q6. Claim sets

**Embedded (14)** from `GET /v3/claimSets`, all `_isSystemReserved: true`:

`SISVendor`, `EdFiSandbox`, `RosterVendor`, `AssessmentVendor`, `AssessmentRead`,
`BootstrapDescriptorsandEdOrgs`, `SeedLoader`, `DistrictHostedSISVendor`, `EdFiODSAdminApp`,
`ABConnect`, `EdFiAPIPublisherReader`, `EdFiAPIPublisherWriter`, `FinanceVendor`,
`EducationPreparationProgram`.

`EdFiSandbox`, `SISVendor`, `AssessmentVendor` and `SeedLoader` are **all present**, so the
SISVendor/AssessmentVendor risk in the plan is closed.

Actions (`GET /v3/actions`): `Create`, `Read`, `Update`, `Delete`, **`ReadChanges`**. Strategies:
13, including `NoFurtherAuthorizationRequired`, `NamespaceBased`, `OwnershipBased`, and the
`RelationshipsWith…` family.

### Adding `DataWarehouse`

| Mechanism | Result |
| --- | --- |
| `POST /v3/claimSets {"claimSetName":"DataWarehouseProbe"}` | 201, but an **empty** claim set; `ClaimSetInsertCommand`/`UpdateCommand` only carry the name. Deleted afterwards (204). |
| **`POST /v3/claimSets/import`** | **201, `{"id":16,"warnings":[]}`: the one to use.** Body = `{claimSetName, resourceClaims[]}` in the same shape as `GET /v3/claimSets/{id}/export`. |
| Re-POSTing the identical import | 201 with the **same id 16** and still one `ClaimSet` row: it behaves as an **upsert** in this build. Handy for idempotency, but undocumented; Task 11 should still `GET` first. |
| `GET /v3/authorizationMetadata?claimSetName=DataWarehouse` | Read-only view for verification (381 claims, one authorization: Read and ReadChanges, both `NoFurtherAuthorizationRequired`). Not a write path. |
| `POST /v3/claimSets/copy` | Exists; copies an existing set (would inherit its CRUD grants, so not useful here). |
| Hybrid claims fragment | Not tried live. Upstream `prepare-dms-claims.ps1` rejects fragments that reference a claim set not already effective (`references unknown effective claim set`), and CMS composes fragments into existing sets. **A fragment can't define a new name**, which confirms the plan's suspicion. |
| `/management/upload-claims`, `/management/reload-claims` | Present in the OpenAPI, but require `EnableManagementEndpoints`/`EnableClaimsetReload` (off in the kit); not pursued. |

### Strategy

Grant `Read` **and `ReadChanges`** with `NoFurtherAuthorizationRequired` on each root of the claims
hierarchy. Children inherit. Roots from `dmscs."ClaimsHierarchy"` (16): `domains/edFiTypes`,
`systemDescriptors`, `managedDescriptors`, `educationOrganizations`, `people`,
`relationshipBasedData`, `assessmentMetadata`, `educationStandards`, `primaryRelationships`,
`ed-fi/educationContent`, `domains/finance`, `ed-fi/crisisEvent`, `ed-fi/studentHealth`,
`publishing/snapshot`, `services/identity`, `domains/tpdm`. The spike's `DataWarehouse.json` used
the first 14; it left out `services/identity` (a service, not data) and `domains/tpdm` (not
loaded).

One resource claim in the import:

```json
{ "name": "people", "claimName": "http://ed-fi.org/identity/claims/domains/people", "parentClaimName": null,
  "actions": [ {"name":"Read","enabled":true}, {"name":"ReadChanges","enabled":true} ],
  "authorizationStrategyOverrides": [
    {"actionName":"Read","authorizationStrategies":[{"name":"NoFurtherAuthorizationRequired"}]},
    {"actionName":"ReadChanges","authorizationStrategies":[{"name":"NoFurtherAuthorizationRequired"}]} ] }
```

The export echoes each root as `Read,ReadChanges` with `Read=NoFurtherAuthorizationRequired
ReadChanges=NoFurtherAuthorizationRequired`.

**Why `ReadChanges` too:** `/deletes`, `/keyChanges` and change-query reads are gated by the separate
`ReadChanges` action (`SISVendor` → `/studentSchoolAssociations/deletes` returned 403 `must grant
permission of the 'ReadChanges' action`). "Read only" for a warehouse must include it, or change-query
extracts (FR-FEAT-4) fail. **Decision needed:** confirm that "Read on everything" includes
`ReadChanges`. The spike assumes yes.

Also note: **`EdFiSandbox` isn't read-everything either.** Its `people` Read uses
`RelationshipsWithEdOrgsAndPeople`, so the bootstrap credential (with no edorg IDs) can't read
arbitrary students.

### Proof

Proven on the populated template (details in Q9): a DataWarehouse credential with
`educationOrganizationIds: []` read all 960 students and got 200 on all 349 collection endpoints
and their `/deletes`; POST, PUT and DELETE returned 403. A claim set imported while DMS is running
returns **500** until DMS's claim-set cache refreshes (up to 10 min).

**Impact:** Task 11: `bootstrap/claimsets/DataWarehouse.json` is exactly the import body above
(reviewable, FR-CLAIM-9); provision it with `/v3/claimSets/import` after a `GET /v3/claimSets` name
check. Byte-identical standard sets: use `GET /v3/claimSets/{id}/export` before and after for the diff.

---

## Q7. Credentials

**Flow** (all from the tools container):

1. `POST /v3/vendors {"company":"…","contactName":"…","contactEmailAddress":"…","namespacePrefixes":"uri://ed-fi.org"}`
   → **201 with an empty body**. The id is **only** in `Location: …/v3/vendors/{id}`. `namespacePrefixes`
   is a comma-separated string (`"uri://ed-fi.org,uri://gbisd.edu"`).
2. `POST /v3/applications {"vendorId":7,"applicationName":"…","claimSetName":"SISVendor","educationOrganizationIds":[99],"dataStoreIds":[1],"profileIds":[1]}`
   → 201 `{"id":…,"key":"<redacted>","secret":"<redacted>"}` (the secret is shown only here).
3. `POST https://localhost:9443/api/oauth/token` with Basic `key:secret` and
   `grant_type=client_credentials` → 200 bearer token (DMS proxies to CMS `/connect/token`). Also works
   internally at `http://dms:8080/api/oauth/token`.

**SEA scoping (PRD open question): an application scoped to SEA `99` alone reaches the LEA and all
three schools.** `SISVendor`, `educationOrganizationIds: [99]`:

```text
GET  /data/ed-fi/schools                        200  [990001,990002,990003]
POST /data/ed-fi/students (S-SEA-1)             201
POST /data/ed-fi/studentSchoolAssociations      201  (student S-SEA-1 at school 990001)
GET  /data/ed-fi/students?studentUniqueId=…     200  ["S-SEA-1"]
```

Negative control, `educationOrganizationIds: [990002]`, same student and school 990001:

```text
POST /data/ed-fi/studentSchoolAssociations      403  "No relationships have been established between the caller's education organization id claim ('990002') and the resource item's 'SchoolId' value."
GET  /data/ed-fi/students?studentUniqueId=S-SEA-1   200  []
```

So DMS walks the SEA → LEA → school hierarchy, and scoping is enforced. Credentials don't need every
ID listed; the SEA alone suffices (and so does the LEA alone, by the same mechanism, though that
wasn't separately tested).

**401 window: none observed.** Five new applications (SeedLoader, EdFiSandbox, SISVendor ×3) each got
a token on the first try (0.06–0.09 s after creation), and the first authorized GET succeeded
immediately (`first GET: HTTP 200 after 0 retries, 0.08s`). The plan's "retry with backoff" risk is
low; keep a short retry anyway. However, DMS **does** cache CMS-side data: Profiles created after
DMS started weren't visible until a DMS restart (Q8). `CacheSettings` in the image:
`ClaimSetsCacheExpirationSeconds 600`, `ApplicationContextCacheExpirationSeconds 600`,
`ProfileCacheExpirationSeconds 1800`, `TokenCacheExpirationSeconds 1500`. So a **claim-set change**
(e.g. re-importing DataWarehouse while DMS runs) may take up to 10 minutes; that wasn't measured.

Other observations:

- Only `SISVendor`/`EdFiSandbox` school reads are `NoFurtherAuthorizationRequired`, so a school-scoped
  SIS credential sees **all** schools (`[990001,990002,990003]` for the 990002 credential). That's
  expected Ed-Fi behavior; worth a sentence in the docs.
- The `SeedLoader` claim set has **no Read** (`GET …/academicSubjectDescriptors` → 403 `must grant
  permission of the 'Read' action`). It can't be used for verification reads.

**Impact:** Task 13: default warehouse → `[]`, SIS/assessment → `[99]` on minimal (the SEA
suffices); on populated, `[255901]` (the sample LEA; there's no sample SEA). Parse the vendor id from
`Location`. Task 10: the bootstrap flow works as specified.

---

## Q8. Features (PRD 3.4)

All are **on by default**; no flags were set. All were run with the SIS or bootstrap credentials in
the tools container.

| Feature | Request | Result |
| --- | --- | --- |
| Available change versions | `GET /api/changeQueries/v1/availableChangeVersions` | 200 `{"oldestChangeVersion":0,"newestChangeVersion":3369}` |
| Change-query window | `GET /data/ed-fi/schools?minChangeVersion=0&maxChangeVersion=3369&totalCount=true` | 200, `Total-Count: 3`; with `minChangeVersion=3369` → 0 |
| Deletes / key changes | `GET /data/ed-fi/schools/deletes`, `/keyChanges` | 200 `[]`; **require the `ReadChanges` action** (403 for SISVendor on `studentSchoolAssociations/deletes`) |
| Profiles: create | `POST /v3/profiles {"name":"Spike-School-Names","definition":"<Profile name=\"Spike-School-Names\"><Resource name=\"School\"><ReadContentType memberSelection=\"IncludeOnly\"><Property name=\"nameOfInstitution\"/></ReadContentType></Resource></Profile>"}` | 201 `Location: …/v3/profiles/1` |
| Profiles: assign | `profileIds:[1]` on `POST /v3/applications` | Stored (`GET /v3/applications/5` → `"profileIds":[1]`) |
| Profiles: select | `Accept: application/vnd.ed-fi.school.spike-school-names.readable+json` (case-insensitive) | 200, body limited to `nameOfInstitution`, `schoolId`, `id`, `_etag`, `_lastModifiedDate` |
| Profiles: implicit | Same app, no profile Accept header | Also filtered (single assigned profile applies by default) |
| Profiles: unknown name | `…school.nope.readable+json` | 406 `The profile 'nope' specified by the content type in the 'Accept' header is not supported by this host.` |
| ETag | `GET /data/ed-fi/students/{id}` | `ETag: "3367-a0d39468.j._.l.i"`; body `_etag` matches |
| `If-Match` mismatch | `PUT` with `If-Match: "3000-bogus"` | **412** `Optimistic Lock Failed` |
| `If-Match` current | `PUT` with the current ETag | 204, new `ETag: "3370-…"`; reusing the old one → 412 |
| `If-None-Match` | `GET …/{id}` with the current ETag | **304** |
| limit/offset | `GET /data/ed-fi/academicSubjectDescriptors?limit=2&offset=2&totalCount=true` | 200, `Total-Count: 19`, `["Composite","English"]` |
| Max page size | `?limit=501` | 400 `Limit must be omitted or set to a numeric value between 0 and 500.` (`MAXIMUM_PAGE_SIZE`) |
| Cursor paging | `pageToken` + `pageSize`; first token from a `limit=` response's **`Next-Page-Token`** header, or from `GET /data/ed-fi/{resource}/partitions?number=N` → `{"pageTokens":[…]}` | `?pageSize=5&pageToken=<Next-Page-Token>` → next 5 rows plus a new `Next-Page-Token` |
| Cursor rules | `?pageSize=5` alone | 400 `PageToken is required when pageSize is specified.`; `pageSize`+`offset` → 400 `Use limit instead of pageSize when using limit/offset paging.` |
| XSD metadata | `GET /api/metadata/xsd` → `[{"name":"ed-fi","version":"5.2.0","files":"https://localhost:9443/api/metadata/xsd/ed-fi/files"}]`; `…/ed-fi/files` → list of `…/ed-fi/Ed-Fi-Core.xsd`, … | 200 |
| OpenAPI metadata | `GET /api/metadata/specifications` → Resources, Descriptors, Discovery; `resources-spec.json` 200, 4.27 MB | 200 |

Other OpenAPI query parameters: `fields`, `q` (date-range query expression), `Use-Snapshot` header,
and `numberOfPartitions` as `number`. 690 paths, including `/deletes`, `/keyChanges`, `/partitions`
per resource.

Findings:

- **Profile cache:** a profile created while DMS was running was **not usable** until DMS
  restarted. DMS logged `Profile ID 1 not found in profile store for application 5` and returned 406.
  After `docker compose restart dms` it worked. So profiles should be created during bootstrap
  before DMS starts, or the docs should say "restart DMS or wait up to 30 min
  (`ProfileCacheExpirationSeconds 1800`)".
- **A client with no assigned profiles can opt into any profile** via the Accept header
  (`sis-sea`, `profileIds: []`, got the filtered view). This only narrows what the client gets, but
  ODS/API 7 returns an error for an unassigned profile. It's a behavioral difference worth
  recording, or an upstream issue.
- `_changeVersion` isn't in resource bodies; change versions only show up through the query
  parameters and the ETag prefix.
- `Location` headers on direct `http://dms:8080` calls use `http://dms:8080/...`; through NGINX they
  use the public origin.

**Impact:** Checkpoint B: no feature needs enabling, and there's no known-limitation entry for
3.4 yet. Task 14: the smoke test must obtain the first cursor token from `Next-Page-Token`/`partitions`,
not from `pageSize` alone. Task 11: warehouse needs `ReadChanges`. Profiles: document the restart.

---

## Q9. Templates

**Source:** `https://github.com/Ed-Fi-Alliance-OSS/Ed-Fi-Standard/archive/refs/tags/v5.2.0.zip`
redirects to the **`Ed-Fi-Data-Standard`** repo; use
`https://github.com/Ed-Fi-Alliance-OSS/Ed-Fi-Data-Standard/archive/refs/tags/v5.2.0.zip`
(`data-standard.psm1` does). 4,374,028 bytes, SHA-256
`a0e3ee6f8e17a71a4ad4134f1ab65d887a455a718d260f8905f7db8a034b43b7` (GitHub archive zips aren't
guaranteed byte-stable over time, so a checksum pin can break; FR-TMPL-7 should verify content
instead, or Ed-Fi should publish a release asset). Extracted top dir: `Ed-Fi-Data-Standard-5.2.0/`
(`Descriptors/` 203 files 1.5 MB; `Samples/Sample XML/` 58 files **165 MB**; `Schemas/Bulk/` 27 XSDs).

**BulkLoadClient invocation** (tools container, working dir `/work`, upstream tuning):

```sh
bulkloadclient -b http://dms:8080/api -o http://dms:8080/api/oauth/token \
  -d <dataDir> -w "$(mktemp -d /work/blc.XXXX)" -k <key> -s <secret> \
  -x /…/Ed-Fi-Data-Standard-5.2.0/Schemas/Bulk -c 10 -l 10 -t 5 -r 2
```

`-b` is the DMS base **including** `/api`; BulkLoadClient reads `/api/metadata/specifications`,
`/metadata/dependencies`, and uses the local `-x` XSDs (`Xsd files found … skipping download`).

**SchoolYearType (upstream `Invoke-SchoolYearTypeRestPrecondition`):** `POST /data/ed-fi/schoolYearTypes`
for 1991–2037, `{"schoolYear":Y,"schoolYearDescription":"Y-1-Y","currentSchoolYear":Y==current}`, with
the SeedLoader credential, before any bulk pass, because SchoolYearType is a closed XSD enumeration
with no interchange. 47 rows in ~3 s. **Re-POST returns 200 (upsert), not 409**, so it's idempotent.

### Minimal (descriptors only)

`-d …/Descriptors` directly (files named `*Descriptor.xml`, root `<InterchangeDescriptors>`):

| Metric | Value |
| --- | --- |
| Wall clock (container start → exit) | **17 s** |
| Result | exit 0; **3,303 × `201`**, 0 errors (= the 3,303 `<CodeValue>` elements in `Descriptors/`) |
| `dms."Descriptor"` rows | 3,303 |
| `pg_database_size` | 50 MB (52,236,771) before → 54 MB (56,652,259) after descriptors; 55 MB after SchoolYearTypes, the baseline hierarchy and test students |
| Named volume on disk (`docker system df -v`) | `db-data` 131.6 MB (includes WAL), `api-schema` 14.5 MB |

### Populated (descriptors + `Samples/Sample XML`)

Staging, as upstream `New-SeedWorkspace` does: descriptor tier = `Descriptors/*.xml` plus the
sample `*Descriptor.xml` files (8; the sample copy wins for `DiagnosisDescriptor.xml`, the one
collision), 210 files. Resource tier = the other 50 sample files, placed under
`<InterchangeName>/<file>` from each file's `<Interchange…>` root element, across 23 interchanges.
This matters: BulkLoadClient only finds `Name.xml`, `Name-*.xml`, or `Name/*.xml`, and names like
`AssessmentSample.xml`, `StudentSchoolAttendance.xml`, `StudentTransportation.xml` don't match
their interchange (`AssessmentMetadata`, `StudentAttendance`, `StudentEnrollment`).

**Run 1** (SeedLoader with `educationOrganizationIds: []`, `namespacePrefixes: uri://ed-fi.org`),
clean volume:

- Descriptor tier: 17 s, exit 1: 3,301 × 201, **1 × 403** (`ProgramCharacteristicDescriptor.xml`:
  `The 'Namespace' value of the data does not start with any of the caller's associated namespace
  prefixes ('uri://ed-fi.org')`; that file uses `uri://gbisd.edu`).
- Resource tier: **397 s**, exit 1: 10,189 × 201, **271,613 × 403**, 508 × 409, 268 × 500, 12 × 400.
  The 403s are `No relationships have been established between the caller's education organization
  id claims (none) and … 'SchoolId', 'StudentUniqueId'`. **`SeedLoader` uses relationship-based
  strategies for student data, so it needs edorg IDs.** DB ended at only 78 MB.

**Run 2** (SeedLoader with `educationOrganizationIds: [255901, 255950, 6000203]`,
`namespacePrefixes: "uri://ed-fi.org,uri://gbisd.edu"`), clean volume:

| Metric | Value |
| --- | --- |
| Descriptor tier | **19 s**, exit 0, 3,325 descriptors (`dms."Descriptor"`) |
| Resource tier | **294 s**, exit 1: **101,411 × 201, 3 × 403**, nothing else (no 409/500/400) |
| The 3 errors | `EducationOrganization.xml CommunityProviderLicense`: `No relationships have been established between the caller's education organization id claims ('255901','255950','6000203') and the resource item's 'CommunityProviderId' value.` Add community provider **19255901** to the SeedLoader edorgs to reach exit 0 (not re-run). |
| Load wall clock | ~5.3 min for BulkLoadClient (19 s + 294 s) + ~3 s SchoolYearType; **8 min** for the whole clean stack (`down -v` → populated), including ~60 s of spike-script polling |
| `pg_database_size` | 49.4 MB empty schema → 54.6 MB after descriptors → **194 MB** (203,837,923 bytes) populated |
| Named volume on disk | `db-data` **700.9 MB** (WAL included), vs 131.6 MB on minimal |
| Counts | 104,795 `dms."Document"`; **960 students**; **3 schools** (+ LEA 255901); 1,873 contacts; 68 staff; 40,320 grades; 13,667 course transcripts; 13,440 student section associations; 71 student health; 12 survey responses |
| DB connections during load | 11–12 client connections (`pg_stat_activity`, sampled every 20 s) |
| DMS warnings/errors during load | 0 lines (live `docker compose logs -f dms` filtered for Warning/Error/Fatal) |

So run 1's 409s and 500s (including the `SurveyResponse` 500s) were **cascades of the authorization
failures**, not defects: they all disappeared once SeedLoader had edorg IDs.

Download/disk/time cost relative to minimal (FR-TMPL-10): the same 4.4 MB zip (both templates need
it; minimal uses only `Descriptors/`), +165 MB extracted XML if staged, **+~140 MB database / +~570 MB
volume**, **+~5 min** first start on this host.

### DataWarehouse proof (populated, Q6)

`POST /v3/claimSets/import` (DataWarehouse, 14 roots) then `POST /v3/applications`
`{"claimSetName":"DataWarehouse","educationOrganizationIds":[],"dataStoreIds":[1]}`:

```text
GET  /data/ed-fi/students?limit=1&totalCount=true           200  Total-Count: 960
GET  /data/ed-fi/studentSchoolAssociations?…                200  Total-Count: 960
GET  /data/ed-fi/grades?…                                   200  Total-Count: 40320
GET  /data/ed-fi/contacts?…  /staffs?…  /studentHealths?…   200  1873 / 68 / 71
GET  /data/ed-fi/schools?totalCount=true                    200  [255901107,255901044,255901001,990001,990002,990003]
GET  /data/ed-fi/students/deletes                           200
GET  /data/ed-fi/students?minChangeVersion=0&totalCount=true 200 Total-Count: 960
POST   /data/ed-fi/students                                 403  "…(currently 'DataWarehouse') must grant permission of the 'Create' action…"
PUT    /data/ed-fi/students/{id}                            403  "…'Update' action…"
DELETE /data/ed-fi/students/{id}                            403  "…'Delete' action…"
POST   /data/ed-fi/academicSubjectDescriptors               403  "…'Create' action…"
```

A sweep of **all 349 collection endpoints** in `resources-spec.json` + `descriptors-spec.json`
(`GET /data{path}?limit=1` and `…/deletes?limit=1`): **0 non-200**.

**Claim-set cache finding:** straight after the import, while DMS was running, every DataWarehouse
request returned **HTTP 500** `"No security metadata has been configured for this resource."` (a 500,
not a 403). It started working **without a restart** 2 min later: import at 22:59:31, first 200 at
23:01:36. That's consistent with `ClaimSetsCacheExpirationSeconds 600` counted from DMS's first load
(~22:52). **Worst case is ~10 minutes, or restart DMS.** Task 11 should import the claim set before
DMS starts, or restart DMS after importing. The misleading 500 is worth an upstream issue.

The baseline hierarchy was also created on the populated data with EdFiSandbox: all 5 records 201,
and they coexist with the sample organizations (6 schools total, 2 LEAs), so FR-EDORG-8 holds.

### Sample education organizations

From `EducationOrganization.xml`: LEA **255901** (Grand Bend ISD), schools **255901001, 255901044,
255901107**, education service center **255950**, post-secondary institution **6000203**. There is
**no StateEducationAgency** in the sample. 960 distinct `StudentUniqueId`s in `Student.xml`.
**No collision** with the baseline 99 / 9900 / 990001–990003. The one namespace besides `uri://ed-fi.org`
is `uri://gbisd.edu` (267 uses).

**Impact:** Task 8: the SeedLoader vendor needs `uri://ed-fi.org` (and `uri://gbisd.edu` for populated),
and `-d` can point at `Descriptors/` directly. Task 9: stage by root element; SeedLoader
`educationOrganizationIds` = the sample LEA (and ESC/PSI); fail on a non-zero BulkLoadClient exit, but
decide which residual errors are tolerable (below). Load cost numbers for FR-TMPL-10 are in the tables.

---

## Q10. Ingress spot checks

| Check | Result |
| --- | --- |
| `/swagger/` loads | **FAIL as shipped.** `200` with a **0-byte** body. `/usr/share/nginx/html/index.html` is empty. Root cause below. After regenerating `index.html` by hand in the container: 200, 1,894 bytes, `DMS_BASE_PATH = "/api"`, all kit JS files 200, `/swagger` → 301 `/swagger/`. |
| "Try it out" with a token | **Not verified in a browser.** The equivalent same-origin calls work: `POST https://localhost:9443/api/oauth/token` → 200, then `GET https://localhost:9443/api/data/ed-fi/schools` with that token → 200; `/api/metadata/specifications` advertises `https://localhost:9443/api/metadata/specifications/resources-spec.json`. |
| `/pgadmin/` logs in, shows server | `GET /pgadmin/login` 200; `POST /pgadmin/authenticate/login` (email, password, csrf) → 302 `/pgadmin`; `/pgadmin/browser/` 200. pgAdmin's DB has group `Ed-Fi Pilot Kit` with server `Ed-Fi API v8 (DMS + CMS)`, `db:5432`, maintenance DB `postgres`, user `postgres` (logged `Added 1 Server Group(s) and 1 Server(s).`). Connecting prompts for the DB password; that's expected, and should be documented. |
| `/data/v3/ed-fi/schools` = `/api/data/ed-fi/schools` | Both 200; `cmp` of the two bodies: identical (3 schools). Access log: `"request_uri":"/data/v3/ed-fi/schools","uri":"/api/data/ed-fi/schools","data_v3_rewrite":true`. |
| `http://` → 301 | `curl http://localhost:9080/api/data/ed-fi/schools?limit=1` → `301 -> https://localhost:9443/api/data/ed-fi/schools?limit=1` |
| DMS stopped → JSON 503 | `/api`, `/api/data/ed-fi/schools`, `/data/v3/ed-fi/schools` → `503 application/problem+json` `{"type":"urn:ed-fi:kit:service-unavailable","title":"Service Unavailable","status":503,"detail":"The dms service is not reachable. It may still be starting, or it may have stopped.","hint":"docker compose ps dms; docker compose logs dms","service":"dms","correlationId":"…"}`. `/config/v3/vendors` still 401 (CMS unaffected). |
| `logs/nginx/access.json` | 52 lines, every line parses with `jq -e .` (0 invalid). Fields: `time`, `request_id`, `correlation_id`, `status`, `request_time`, `upstream_response_time`, `service`, `total_count`, `data_v3_rewrite`, … |
| Correlation ID | Request with `correlationid: spike-corr-12345` → 1 match in `access.json`, 3 in `docker compose logs dms` (FR-LOG, Task 15). |

**Swagger root cause:** `compose.ingress.yml` uses `command: >` with continuation lines indented
more than the first line. YAML keeps newlines for more-indented lines in a folded scalar, so the
container gets `envsubst '…'\n < index.html > …/index.html && cp … && exec nginx`
(`docker inspect … .Config.Cmd` shows the literal `\n`). `sh` runs `envsubst` with empty stdin
(exit 0), and then the redirect-only second line truncates `index.html`. Fix: put the command on one
line, use `command: ["sh", "-c", "envsubst … < … > … && cp … && exec nginx -g 'daemon off;'"]`, or
keep all folded lines at the same indent.

Also: Swagger UI loads `swagger-ui-dist@5.25.2` from **unpkg.com** (no SRI), so it needs internet
at browse time. That's worth a known-limitation line, or vendoring.

**Impact:** Task 7: fix the command, then do a real browser "Try it out" check. Task 15: logging
works as configured.

### DMS log volume (Task 15)

At `DMS_LOG_LEVEL=Information`, DMS writes several JSON lines per request. After the run-1
populated load, `docker compose logs dms` returned 180,141 lines, all `Information`, whose
**oldest line was 22:47:50, while the load started at 22:41**. Docker's json-file rotation
(`DOCKER_LOG_MAX_SIZE=50m`, `DOCKER_LOG_MAX_FILE=5`) had already discarded the load window, including
whatever DMS logged for the 268 × 500s. For a pilot that needs error evidence, default
`DMS_LOG_LEVEL` to `Warning` during template loads, or raise the rotation limits. Run 2 captured
warnings and errors with a live `logs -f` filter (below).

---

## Recommended changes

Tools image (`ed-fi-api-v8/tools/Dockerfile`, README):

1. After the build-time smoke check, `rm -f /opt/bulkloadclient/logfile.txt` and make the file
   appender writable. For example, `chown 1654:1654 /opt/bulkloadclient` or replace `log4net.config`'s
   `<file value="logfile.txt"/>` with `/work/logfile.txt`. (Evidence: 21,815 log4net errors during the
   minimal load.) Fix the README's claim that it logs to the current directory.
2. `RUN install -d -o 1654 -g 1654 /app/ApiSchema` so a fresh `api-schema` volume is writable by the
   non-root user. (Evidence: `Permission denied` → `WRITE-OK` with a derived image.)
3. Add `unzip` to the apt list (needed for the Data Standard zip, and for the nupkg if you use option 2
   in Q3).

Compose / init:

4. `compose.ingress.yml` swagger-ui `command:`: make it a single line or an exec-form array (Q10).
5. Stage the ApiSchema volume **before DMS ever mounts it**; stage from the DMS image (Q3 option 1),
   including `JsonSchemaForApiSchema.json` and a core-only `bootstrap-api-schema-manifest.json`;
   verify the `ApiSchema.json` SHA-256 and that the manifest lists only `ed-fi`. Gate DMS on it with
   `service_completed_successfully`.
6. Init order: `db` → `init-identity` (key + clients; can run after CMS) → `config` healthy →
   `init-datastore` → `init-api-schema` → `init-schema` (`ddl provision`) → `dms`. DMS fatal-exits
   without a data store or schema files, so these must complete first.
7. `.env.example`: add `CMS_ADMIN_CLIENT_SECRET` (admin client) and `DMS_DB_MAX_POOL_SIZE` (feeds the data
   store connection string); consider `DMS_LOG_LEVEL=Warning` during initialization (log rotation
   evidence).
8. Data store body: `dataStoreType: "Development"` (or similar), `provider: "postgresql"` (lowercase).

Bootstrap / claims / credentials:

9. SeedLoader application: `namespacePrefixes "uri://ed-fi.org,uri://gbisd.edu"`, and
   `educationOrganizationIds` = `255901, 255950, 6000203, 19255901` (LEA, ESC, PSI, community provider)
   for populated. Minimal needs none. (Evidence: run 1, 271,613 × 403; run 2, 3 × 403, all
   `CommunityProviderId`.)
10. DataWarehouse = `/v3/claimSets/import` with Read + **ReadChanges** × `NoFurtherAuthorizationRequired`
    on the 14 hierarchy roots listed in Q6. Keep the file as the import body. **Import it before DMS
    starts** (or restart DMS afterwards); otherwise DMS returns 500 "No security metadata" for up to
    10 minutes.
11. Create Profiles (if the kit ships any) before DMS starts, or restart DMS after creating them.
12. Parse CMS ids from the `Location` header (`POST /v3/vendors` has no body).
13. Populated template staging: place each sample file by its root `<Interchange…>` element.
14. Fix the Data Standard URL to `Ed-Fi-Data-Standard`; don't rely on the GitHub archive checksum
    staying stable.
15. Host `.sh` wrappers: `export MSYS_NO_PATHCONV=1` for Git Bash on Windows.

Plan updates:

16. `plan.md` risk "SISVendor/AssessmentVendor not embedded": closed (present).
17. `plan.md` risk "new CMS client returns 401 briefly": not observed; the real cache risks are
    Profiles (406 until refresh or restart, up to 30 min) and claim sets (500 until refresh or restart,
    up to 10 min; observed 2 min).
19. Consider upstream issues: (a) 500 instead of 403 for a claim set DMS hasn't cached yet; (b) an
    unassigned Profile is honored when a client asks for it; (c) log4net path in BulkLoadClient.
18. PRD open question (SEA scoping): an SEA-only application reaches its LEAs and schools.

## Still unknown

- **arm64** build and run of the tools image (only amd64 tested).
- **Browser** "Try it out" in Swagger UI (curl-level equivalent passed; the UI was broken as shipped).
- Whether `ddl provision` works as a **non-superuser** (the kit uses `postgres`).
- Whether **modifying** an already-cached claim set (as opposed to adding a new one) also takes up to
  10 minutes (only a new claim set was measured: 2 min, within a 600 s window).
- Whether a populated load reaches **exit 0** with `19255901` added to the SeedLoader edorgs (inferred
  from the 3 error messages; not re-run).
- Populated load time on a slower or arm64 host (only this Windows/WSL2 host measured).
- Whether `volume: nocopy: true` on the DMS mount reliably prevents the copy-up trap.
- Whether the `Maximum Pool Size` ceiling is honored under load (only 12 connections observed).
- Whether the Hybrid claims mode could ever create a new claim set (inferred "no" from upstream
  validation; not tried live).
- `.nupkg` availability and immutability on the Ed-Fi feed for the pilot duration (not checked beyond
  one download).

---

AI assistance: this spike was run and these notes were drafted by Claude (Claude Code). Every result
above comes from commands actually run on the host described at the top. Interpretations are
marked as such, and the "Still unknown" list names what wasn't verified. Review before relying on it.
