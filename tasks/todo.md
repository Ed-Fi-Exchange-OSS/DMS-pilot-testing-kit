# Task List: Ed-Fi API v8 Docker Compose Kit

See [plan.md](./plan.md) for context, decisions, risks, and open questions. All paths are relative to
the repository root; new work lives in `ed-fi-api-v8/`.

Common verification command (defined in Task 12, used informally before then):
`docker compose -f ed-fi-api-v8/compose.yml --env-file ed-fi-api-v8/.env up -d --wait`

## Status (2026-09-29)

The Phase 0 spike ran on a host with Docker; its results are in [spike-notes.md](./spike-notes.md).
The sandbox still has no Docker daemon, so new work is drafted here and verified on the host.

- Task 1: done. Every question is answered or listed under "Still unknown" in the notes.
- Task 2: verified by the spike (`db` and `config` reach healthy on clean volumes).
- Tasks 5, 6, 7, 15 (NGINX parts): spot-checked by the spike (spike-notes Q10). The Swagger UI
  empty-page bug it found is fixed; the browser "Try it out" check is still open.
- Tools image: the spike's three defects (log4net path, no `unzip`, unwritable `api-schema` volume)
  are fixed in `tools/Dockerfile`, pending a host rebuild.
- Tasks 3 and 4: done, and Checkpoint A's clean start and no-op rerun pass on the host. Items still
  unchecked below were tested only in the sandbox (secret rotation, invalid secrets, TPDM restaging).
- Tasks 8 and 11: done and verified on the host (clean minimal load, rerun skip, template-change
  warning, DataWarehouse import with no warnings). DataWarehouse credential checks wait for Task 13.
- Task 10: done and verified on the host (5 baseline records, credentials file readable by the host
  user, rerun reuses the credential and creates nothing, a deleted school is recreated).
- Next: Task 9 (populated template) and Task 18 (claim set reload endpoint), then Phase 4.

---

## Phase 0: De-risk

## Task 1: Spike: standalone schema provisioning, claim sets, and seed loading

**Description:** Answer, with evidence, the unknowns that shape every later task. Find out:

- the `EdFi.Api.SchemaTools` `8.0.1-alpha.0.164` global tool in a container: the exact `ddl provision`
  flags, and whether it runs on `dotnet/runtime` after a multi-stage build
- whether `EdFiSandbox`, `SISVendor`, and `AssessmentVendor` are embedded in
  CMS
- how to create a new claim set through CMS
- whether change queries, Profiles, ETags, and cursor paging need any flag
- how long a Populated load takes through BulkLoadClient in a container

Throwaway code is fine. The deliverable is the notes file.

**Acceptance criteria:**
- [x] `tasks/spike-notes.md` records each answer with the command or endpoint used as evidence
- [x] A working, pinned container recipe for `EdFi.Api.SchemaTools` that provisions a schema DMS accepts
- [x] Measured wall time and DB size for the minimal and populated loads

**Verification:**
- [x] Manual check: a hand-run stack returns 200 for an authenticated `GET /api/data/ed-fi/schools`

**Dependencies:** None
**Files likely touched:** `tasks/spike-notes.md` (and a draft of `ed-fi-api-v8/tools/Dockerfile`, which Task 4 finishes)
**Estimated scope:** M (research)

---

## Phase 1: Core stack

## Task 2: Compose skeleton and `.env.example`

**Description:** Create `ed-fi-api-v8/compose.yml`, with the `db` (PostgreSQL), `config` (CMS), and
`dms` services derived from the copied files. Strip Keycloak, Kafka, MSSQL, multi-tenancy, plugins,
OTLP, and route qualifiers. Use a project-scoped network and named volume, pinned images, bounded
health checks, and `127.0.0.1` bindings. Create a commented `.env.example` with local-dev-only labels. Pin the DMS image to
`edfialliance/ed-fi-api:8.0.1-alpha.0.164@sha256:f0c467be…` and CMS to
`edfialliance/ed-fi-api-configuration-service:pre@sha256:57c0afed…` (full digests in `plan.md`).

**Acceptance criteria:**
- [ ] `docker compose config` succeeds using only `.env.example` copied to `.env`
- [ ] Every image is a pinned tag or digest supplied through `.env` (FR-PLAT-5)
- [ ] Health checks have bounded `retries`/`start_period`; no fixed sleeps (NFR-REL-1/2)
- [ ] License headers on all files (NFR-MAINT-4); `.gitignore` covers `.env`, `.runtime/`, `logs/`, `ssl/*.key`

**Verification:**
- [x] `docker compose up -d db config` → both healthy (spike, clean run 2)

**Dependencies:** Task 1
**Files likely touched:** `ed-fi-api-v8/compose.yml`, `ed-fi-api-v8/.env.example`, `.gitignore`
**Estimated scope:** S

## Task 3: Identity init container

**Description:** A one-shot `init-identity` service (tools image) that runs after CMS is healthy.
CMS's own database deploy creates the `dmscs` tables and the `pgcrypto` extension, and CMS reads the
signing key lazily on the first token request, so no pre-CMS step or restart is needed (spike Q2).
The spike's working recipe is in spike-notes Q2; port it to `sh` with `openssl` and `psql`, no .NET.

1. **Signing key**, if no active row exists in `dmscs."OpenIddictKey"`. Generate RSA 2048 as
   **PKCS#8** DER (`openssl genpkey … | openssl pkcs8 -topk8 -nocrypt -outform DER`; plain
   `genpkey -outform DER` writes PKCS#1 and CMS returns 500 on every token request). Store the SPKI
   public key and `pgp_sym_encrypt(private, CMS_IDENTITY_ENCRYPTION_KEY)`. Check table existence and
   row existence as two queries (a combined `to_regclass … AND EXISTS` fails to plan when the table
   is absent).
2. **Clients**, each with both the `dms-client` and `cms-client` roles and a `namespacePrefixes`
   protocol mapper, as upstream `setup-openiddict.ps1` does:

   | Client | Secret (`.env`) | Scope |
   | --- | --- | --- |
   | `DmsConfigurationService` | `CMS_SERVICE_CLIENT_SECRET` | `edfi_admin_api/full_access` |
   | `CMSReadOnlyAccess` | `CMS_READONLY_CLIENT_SECRET` | `edfi_admin_api/readonly_access` |
   | `PilotKitAdmin` | `CMS_ADMIN_CLIENT_SECRET` | `edfi_admin_api/full_access` |

3. **Secret hash:** ASP.NET Identity v3 format (`0x01`, int32 LE 16, 16-byte salt, PBKDF2-HMAC-SHA256
   with 210000 iterations and 32 bytes, base64), computed with `openssl kdf`. The iteration count
   must match `IdentitySettings__HashingIterations`.
4. **Reconcile secrets on every run** (decision 9 in plan.md): for an existing client, re-derive the
   hash from `.env` with the stored salt; if it differs, update `ClientSecret`. Otherwise change
   nothing.
5. Validate each secret before touching the database (32–128 characters; lowercase, uppercase,
   digit, special), and fail with a message that names the `.env` variable.

Pass values to SQL as psql variables (`-v name=value`, `:'name'`), never by string concatenation.

**Acceptance criteria:**
- [x] Clean start: CMS `/connect/token` issues a `PilotKitAdmin` token, and DMS logs no 401 from CMS
- [x] Second `up` makes no new key or client rows, and exits 0
- [ ] Changing a client secret in `.env` and running `up` again updates only that client; the old
      secret stops working and the new one works
- [ ] An invalid secret in `.env` fails `init-identity` with a message naming the variable
- [ ] Secrets come from `.env`, never hard-coded, and never appear in logs

**Verification:**
- [ ] `docker compose up --wait` twice; `SELECT count(*)` from the key and application tables is unchanged

**Dependencies:** Task 2
**Files likely touched:** `ed-fi-api-v8/compose.init.yml`, `ed-fi-api-v8/init/identity.sh`, `ed-fi-api-v8/init/lib.sh`
**Estimated scope:** M

## Task 4: Schema and data store init

**Description:** Three one-shot services, run before DMS. DMS exits in a restart loop without a
registered data store or without its ApiSchema files (spike Q3, Q4), so it `depends_on` all of them
with `service_completed_successfully`, and on `init-identity`.

1. **`init-api-schema`** stages the ApiSchema volume from the pinned DMS image (decision 10 in
   plan.md), not from the NuGet package. `image: ${DMS_IMAGE}`, `entrypoint: sh`, running as root
   (a new volume is root-owned), with the `api-schema` volume mounted at `/stage` (not
   `/app/ApiSchema`, which would trigger Docker's copy-up). It copies `JsonSchemaForApiSchema.json`
   and `Packages/EdFi.DataStandard52.ApiSchema/` (`ApiSchema.json`, `discovery-spec.json`, `xsd/`)
   from the image's `/app/ApiSchema`, and writes a core-only `bootstrap-api-schema-manifest.json`
   with `jq` (layout in spike-notes Q3). All four files are required.
   - Verify `ApiSchema.json` against a pin in `.env`:
     `API_SCHEMA_SHA256=1051c5c3d1b2a3e488460a08a82f65a22fc49802b361df66dff8195b5aac5e73`
     (byte-identical to `EdFi.DataStandard52.ApiSchema` 1.0.335).
   - Fail if the manifest lists any project other than `ed-fi`.
   - Idempotency: if the volume already holds exactly the expected files and hash, change nothing.
     Otherwise (empty, TPDM from an earlier copy-up, or a different hash), clear it and restage.
2. **`init-datastore`** (tools image, after `init-identity`) registers the data store with a
   `PilotKitAdmin` token, if `GET /v3/dataStores` has no entry with the kit's name:
   `POST /v3/dataStores {"name":"Pilot Kit","dataStoreType":"Development","provider":"postgresql","connectionString":"host=db;…;Maximum Pool Size=${DMS_DB_MAX_POOL_SIZE}"}`.
   `provider` must be lowercase. No data store context is needed.
3. **`init-schema`** (tools image, after `init-api-schema`, as `postgres`) runs
   `api-schema-tools ddl provision --schema <volume>/Packages/EdFi.DataStandard52.ApiSchema/ApiSchema.json --connection-string … --dialect pgsql --create-database`.
   Skip when `dms."EffectiveSchema"` already holds the expected hash (`api-schema-tools hash`); fail
   with a clear message when it holds a different hash, since that requires a reset.

Also:

- Mount the volume in DMS with `volume: {nocopy: true}` as a second guard against copy-up
  (untested; confirm on the host).
- The admin-token and "GET before POST" helpers go in `init/lib.sh`, shared with Tasks 8–13.
- Imports of kit claim sets (Task 11) also belong in this pre-DMS chain, since they only need CMS.

**Acceptance criteria:**
- [x] Clean `up --wait` → DMS healthy; `GET /api` Discovery returns 200 with DS 5.2 and no TPDM
- [x] `dms."EffectiveSchema"` hash is `a0d39468ef30d3e99273065256bfffa42b799404ca5fbc09a8648f349d9217e1`
- [x] Re-run doesn't re-register the data store, restage the volume, or re-provision
- [ ] A volume pre-filled with TPDM (from copy-up) is detected and restaged as core only
- [ ] Failure of any init step makes `up --wait` fail and names the service
- [x] `GET /api/metadata/xsd/ed-fi/files` and `/api/metadata/specifications/discovery-spec.json` return 200

**Verification:**
- [ ] Manual: create a vendor and application via CMS by hand, get a token, and `GET` a descriptor list → 200

**Dependencies:** Task 3
**Files likely touched:** `ed-fi-api-v8/compose.core.yml`, `ed-fi-api-v8/compose.init.yml`, `ed-fi-api-v8/.env.example`, `ed-fi-api-v8/init/api-schema.sh`, `ed-fi-api-v8/init/datastore.sh`, `ed-fi-api-v8/init/provision-schema.sh`
**Estimated scope:** M

### Checkpoint A
- [x] Clean-volume `up --wait` succeeds; restart preserves data; second `up` is a no-op
- [ ] Review with human before proceeding

---

## Phase 2: Ingress

## Task 5: NGINX HTTPS ingress and certificates

**Description:** Add an `nginx` service with a `default.conf.template`, adapted from `ods-api-compose`:

- redirect HTTP to HTTPS
- proxy `/api` to DMS and `/config` to CMS
- send forwarded headers
- return 503 via `@unavailable` when a backend is down

Add `ssl/generate-certificate.sh` and `.ps1`, with SANs for localhost. Set
DMS/CMS `PathBase` and forwarded-header trust. Make host ports configurable.

**Acceptance criteria:**
- [ ] `curl -k https://localhost/api` Discovery shows `https://localhost/...` URLs (FR-ROUTE-4)
- [ ] `http://` → 301 to https; stopping DMS returns 503, not 502 (FR-ROUTE-9). Both seen in the
      spike (Q10); recheck after Checkpoint A
- [ ] Missing certificate files → nginx fails with an actionable message, and the cert script fixes it

**Verification:**
- [ ] Token via `https://localhost/api/oauth/token`, then an authenticated GET, both through NGINX

**Dependencies:** Checkpoint A
**Files likely touched:** `ed-fi-api-v8/compose.yml`, `ed-fi-api-v8/nginx/default.conf.template`, `ed-fi-api-v8/ssl/generate-certificate.{sh,ps1}`, `.env.example`
**Estimated scope:** M

## Task 6: `/data/v3` rewrite and opt-in rate limiting

**Description:** Add the `/data/v3/*` → `/api/data/*` rewrite, controlled by `DATA_V3_REWRITE_ENABLED`
(default `true`). Add NGINX `limit_req`, controlled by `RATE_LIMIT_ENABLED` (default `false`) with rate
and burst variables. Implement both by rendering include files at container start, with no template
edits (FR-ROUTE-5/6/8).

**Acceptance criteria:**
- [ ] `GET /data/v3/ed-fi/schools` returns the same body as `/api/data/ed-fi/schools` when enabled; 404 when disabled
- [ ] With rate limiting enabled at a low rate, a burst yields 429s; default config yields none

**Verification:**
- [ ] Both toggles are exercised with `curl`

**Dependencies:** Task 5
**Files likely touched:** `ed-fi-api-v8/nginx/*.template`, `ed-fi-api-v8/nginx/entrypoint.sh`, `.env.example`
**Estimated scope:** S

## Task 7: Swagger UI and PGAdmin behind NGINX

**Description:** Serve the copied `custom-swagger-ui` at `/swagger` (an interim choice; a published Ed-Fi Swagger UI image may replace it), with spec URLs derived from the NGINX origin
instead of `localhost:${DMS_HTTP_PORTS}`. Add PGAdmin at `/pgadmin`
(`SCRIPT_NAME=/pgadmin`), with a preconfigured `servers.json` for the kit database (NFR-OBS-2).

The spike found `/swagger/` served an empty `index.html` (a YAML folded-scalar bug in the
`command:`); that is fixed. `index.html` loads `swagger-ui-dist` from unpkg.com, so the browser needs
internet access: record it as a known limitation, or vendor the files.

**Acceptance criteria:**
- [ ] `/swagger` loads the Resources and Descriptors specs and "Try it out" succeeds with a token (FR-FEAT-3)
- [ ] `/pgadmin` shows the preconfigured server
- [ ] XSD and OpenAPI metadata endpoints are reachable under `/api/metadata`

**Verification:**
- [ ] Manual browser check of both UIs

**Dependencies:** Task 5
**Files likely touched:** `ed-fi-api-v8/swagger-ui/*`, `ed-fi-api-v8/pgadmin/servers.json`, `ed-fi-api-v8/compose.yml`, nginx template
**Estimated scope:** M

### Checkpoint B
- [ ] All participant URLs work over HTTPS; the PRD feature list in 3.4 is spot-checked (change queries, ETag, paging, Profiles)
- [ ] Any feature that can't be enabled is written down for the known-limitations doc (FR-FEAT-9b).
      The spike found every 3.4 feature on by default, with no flags (spike-notes Q8).

---

## Phase 3: Data and bootstrapping

## Task 8: Template loader, minimal template, and first-init marker

**Description:** Add an `init-template` one-shot service that runs BulkLoadClient in a pinned .NET
runtime container. It loads the pinned DS v5.2.0 `Descriptors/` XML (plus SchoolYearType via REST),
using a SeedLoader credential created through CMS. `DATABASE_TEMPLATE=minimal|populated` in `.env`
selects the template. A marker table records the template and completion. If the marker exists, the
service skips; if the marker disagrees with `.env`, it warns (FR-TMPL-4/5).

From the spike (Q9):

- Source: `https://github.com/Ed-Fi-Alliance-OSS/Ed-Fi-Data-Standard/archive/refs/tags/v5.2.0.zip`
  (`Ed-Fi-Standard` only redirects). GitHub archive zips aren't guaranteed byte-stable, so verify
  the extracted content rather than relying only on the zip's SHA-256.
- Before BulkLoadClient, POST SchoolYearType 1991–2037 through REST (upsert; re-POST returns 200).
- The SeedLoader vendor needs `namespacePrefixes` `uri://ed-fi.org`. SeedLoader has no Read, so
  verification reads need another credential.
- `bulkloadclient -b http://dms:8080/api -o http://dms:8080/api/oauth/token -d …/Descriptors -w <dir under /work> -x …/Schemas/Bulk -c 10 -l 10 -t 5 -r 2`.
  Minimal took 17 s (3,303 descriptors) on the spike host.
- Fail on a non-zero BulkLoadClient exit.

**Acceptance criteria:**
- [ ] Clean start with the default → descriptor endpoints are populated; no education organizations exist
- [x] Restart does not reload; changing `DATABASE_TEMPLATE` without a reset prints "requires reset" and does not reload
- [ ] Partial failure leaves no marker, so the next start retries

**Verification:**
- [ ] `GET /api/data/ed-fi/gradeLevelDescriptors` count > 0; marker row is present

**Dependencies:** Checkpoint A
**Files likely touched:** `ed-fi-api-v8/init/template.sh`, `ed-fi-api-v8/compose.yml`, `.env.example`
**Estimated scope:** M

## Task 9: Populated template

**Description:** Extend the loader to add `Samples/Sample XML` when `DATABASE_TEMPLATE=populated`.
Fail with an actionable message if the source archive is missing, unreadable, or its checksum doesn't
match (FR-TMPL-7). Record the measured time and disk cost.

From the spike (Q9):

- Stage each sample file under `<InterchangeName>/` by its root `<Interchange…>` element, because
  BulkLoadClient only matches `Name.xml`, `Name-*.xml`, or `Name/*.xml`. The 8 sample descriptor
  files join the descriptor tier (the sample copy wins for `DiagnosisDescriptor.xml`).
- The SeedLoader application needs `namespacePrefixes` `uri://ed-fi.org,uri://gbisd.edu` and
  `educationOrganizationIds` `255901, 255950, 6000203, 19255901` (LEA, ESC, post-secondary
  institution, community provider). Without them 96% of records returned 403. With the first three,
  3 records still failed on `CommunityProviderId`; confirm that adding `19255901` reaches exit 0.
- Measured: about 5.3 min of loading and 8 min for the whole clean stack; the database grows to
  194 MB, and the `db-data` volume to about 700 MB.

**Acceptance criteria:**
- [ ] Clean start with `populated` → students and the sample education organizations are present
- [ ] A corrupted or missing archive fails startup with a message naming the file and the fix; no silent fallback
- [ ] Measured load time and volume size are recorded for docs (FR-TMPL-10, NFR-PORT-5)

**Verification:**
- [ ] `GET /api/data/ed-fi/students?totalCount=true` shows the expected count

**Dependencies:** Task 8
**Files likely touched:** `ed-fi-api-v8/init/template.sh`, `.env.example`
**Estimated scope:** S

## Task 10: Bootstrap credential and baseline hierarchy

**Description:** Add an `init-bootstrap` one-shot service that:

- creates a "Pilot Kit Bootstrap (ADMIN)" vendor and application with
  `EdFiSandbox`, if absent
- writes its key and secret to `.runtime/bootstrap-credentials.json` (the
  secret is only available at creation time, so the file is authoritative)
- creates any missing records from `bootstrap/baseline-edorgs.json`: one SEA,
  one LEA, and elementary, middle, and high schools, with grade levels and
  categories (FR-EDORG-2/4). IDs: SEA `99`, LEA `9900`, schools `990001`, `990002`, `990003`

Each step's failure names the step (FR-BOOT-9).

Parse CMS IDs from the `Location` header: `POST /v3/vendors` returns 201 with an empty body. The
spike created all five baseline records with EdFiSandbox on both templates. Note for the docs:
EdFiSandbox reads `people` through `RelationshipsWithEdOrgsAndPeople`, so the bootstrap credential
can't read arbitrary students.

**Acceptance criteria:**
- [x] Clean minimal start → 5 education organizations exist; credentials file written with IDs
- [x] Re-run → no duplicate vendor, application, or education organizations; missing records are recreated (FR-BOOT-4/5)
- [ ] Works on the populated template too, with IDs that don't collide (FR-EDORG-8)

**Verification:**
- [x] `GET /api/data/ed-fi/schools?localEducationAgencyId=<LEA>` → 3 schools

**Dependencies:** Task 8 (descriptors present)
**Files likely touched:** `ed-fi-api-v8/init/bootstrap.sh`, `ed-fi-api-v8/bootstrap/baseline-edorgs.json`, `ed-fi-api-v8/compose.yml`
**Estimated scope:** M

## Task 11: Data Warehouse claim set

**Description:** Add `bootstrap/claimsets/DataWarehouse.json`, with Read on literally everything: all resources,
descriptors, education organizations, and people. Read is not scoped by education organization
(no-further-authorization-style), and the set grants no Create, Update, or Delete. Leave the
standard claim sets untouched (FR-CLAIM-5..9).

From the spike (Q6) and decision 8 in plan.md:

- The file is the body of `POST /v3/claimSets/import`: `{claimSetName, resourceClaims[]}`, the shape
  `GET /v3/claimSets/{id}/export` returns. `POST /v3/claimSets` creates only an empty set, and a
  Hybrid claims fragment can't define a new claim set name.
- Grant `Read` and `ReadChanges`, both with `NoFurtherAuthorizationRequired`, on the 14 roots of
  the claims hierarchy listed in spike-notes Q6 (all but `services/identity` and `domains/tpdm`).
  `ReadChanges` gates `/deletes`, `/keyChanges`, and change-query extracts.
- Import it in the pre-DMS init chain (`init-claimsets`, after `init-identity`), after a
  `GET /v3/claimSets` name check. A claim set imported while DMS runs returns HTTP 500 `No security
  metadata has been configured for this resource` until DMS's cache refreshes (up to 10 minutes);
  Task 18 covers imports on a running stack.

**Acceptance criteria:**
- [ ] `GET /config/v3/claimSets` lists `DataWarehouse`; its authorization metadata shows only Read
      and ReadChanges
- [ ] A DataWarehouse credential with no education organization IDs can GET every resource and its
      `/deletes`, including students outside the baseline organizations on the populated template;
      POST, PUT, and DELETE return 403
- [ ] The first request with a new DataWarehouse credential after a clean start returns 200, not 500
- [ ] Standard claim sets are byte-identical before and after (export diff)

**Verification:**
- [ ] Scripted check in the smoke test (Task 14)

**Dependencies:** Task 4 (the pre-DMS chain)
**Files likely touched:** `ed-fi-api-v8/bootstrap/claimsets/DataWarehouse.json`, `ed-fi-api-v8/init/claimsets.sh`, `ed-fi-api-v8/compose.init.yml`
**Estimated scope:** S

## Task 18: Enable the DMS claim set reload endpoint

Numbered 18 so that the references to Tasks 12–17 stay valid; it belongs to Phase 3.

**Description:** DMS caches claim sets (`ClaimSetsCacheExpirationSeconds`, 600 s). In the spike, a
claim set imported while DMS was running returned HTTP 500 `No security metadata has been configured
for this resource` until the cache refreshed. Enable the DMS management endpoint that forces a reload,
so that both bootstrap and participants can apply claim set changes immediately (FR-CLAIM-14).

1. Confirm the exact route, method, and authorization with the pinned DMS image. The PRD names
   `POST /management/reload-claimsets`, which would be `/api/management/reload-claimsets` behind NGINX.
   The image exposes the `AppSettings:EnableManagementEndpoints`, `AppSettings:EnableClaimsetReload`, and
   `AppSettings:ManagementEndpoints:RequiredRole` settings, but the spike didn't call the endpoint. Don't
   confuse it with CMS's `/management/reload-claims`.
2. In `compose.core.yml`, drive the settings from `.env`. Replace the current hard-coded
   `AppSettings__EnableManagementEndpoints: "false"`, and add `AppSettings__EnableClaimsetReload`. Set
   a required role so that only an administrative client can call the endpoint, not a participant
   integration credential.
3. Decide which credential calls it (the `PilotKitAdmin` CMS client, or the bootstrap credential), and
   give that client the role through the identity init (Task 3).
4. On a clean start, Task 11 imports DataWarehouse before DMS starts, so no reload is needed. When
   `bootstrap` imports or changes a claim set while DMS is already running, have it call the
   endpoint so that the claim set is usable before it reports success. This removes the
   up-to-10-minute window.
5. Confirm that NGINX routes the endpoint under `/api` and applies no rate limit or rewrite to it.
6. Supply the request, and the credential it needs, to the participant docs (Task 16) and a `.http`
   example (Task 14).

**Acceptance criteria:**
- [ ] With DMS running, importing a new claim set and then POSTing to the reload endpoint makes a
      credential with that claim set succeed immediately, with no 500 and no restart
- [ ] The endpoint rejects a participant integration credential (401 or 403) and an anonymous request
- [ ] With the `.env` switch off, the endpoint isn't available (404), and the rest of the stack is unchanged
- [ ] Bootstrap on a running stack calls the endpoint after changing a claim set, and a failure
      names the step (FR-BOOT-9)

**Verification:**
- [ ] Manual: import a throwaway claim set, reload, then GET with a credential that uses it → 200 at once
- [ ] Scripted check in the smoke test (Task 14)

**Dependencies:** Task 11 (and Task 5 for the NGINX route)
**Files likely touched:** `ed-fi-api-v8/compose.core.yml`, `ed-fi-api-v8/.env.example`, `ed-fi-api-v8/init/identity.sh`, `ed-fi-api-v8/init/bootstrap.sh`, nginx template
**Estimated scope:** S

### Checkpoint C
- [ ] Reset, then start on minimal; reset, then start on populated; each followed by a second start: no errors and no duplicates

---

## Phase 4: Participant tooling

## Task 12: Lifecycle scripts

**Description:** Add `start`, `stop`, `reset`, and `bootstrap`, each as `.ps1` and `.sh` with identical
parameters. Each is a thin wrapper around `docker compose`.

`start`:
1. Checks prerequisites: Docker, `.env`, and certificates.
2. Generates missing secrets into `.env`.
3. Runs `up -d --wait`.
4. On failure, names the failing service and its `docker compose logs` command, then exits non-zero.
5. On success, prints the URLs, the template, the bootstrap-credentials path, and the next step
   (FR-LIFE-1..9).

`reset` requires `--force` or interactive confirmation, and removes volumes. `bootstrap` re-runs
`init-bootstrap` (FR-BOOT-10).

The `.sh` wrappers `export MSYS_NO_PATHCONV=1`: Git Bash on Windows otherwise rewrites container
paths such as `/app/...` into Windows paths (spike Q1).

**Acceptance criteria:**
- [ ] Same flags and same output on bash and pwsh (tested on Linux; pwsh also tested on Windows)
- [ ] `start` against a running stack exits 0, with no changes
- [ ] `reset` without confirmation does nothing

**Verification:**
- [ ] Manual runs of each command, in both shells

**Dependencies:** Checkpoint C
**Files likely touched:** `ed-fi-api-v8/{start,stop,reset,bootstrap}.{sh,ps1}`
**Estimated scope:** M

## Task 13: Credential provisioning scripts

**Description:** Add `new-credential.{sh,ps1}` with these parameters:

| Parameter | Behavior |
| --- | --- |
| `--shape sis\|assessment\|warehouse` | Required. Maps to `SISVendor`, `AssessmentVendor`, or `DataWarehouse`. |
| `--claim-set` | Optional override; unknown values are rejected. |
| `--name` | Required, and must be unique. |
| `--edorg-ids` | Optional. Defaults to the SEA `99` on minimal, or the sample LEA `255901` on populated; the spike showed an SEA-scoped credential reaches its LEA and schools (Q7). Warehouse credentials default to none. |

The script uses the `PilotKitAdmin` CMS client, and reads the new vendor's ID from the `Location`
header. It prints and saves the key and secret to
`.runtime/credentials/<name>.json`, and warns that they can't be recovered. It fails clearly when CMS
isn't ready (FR-CRED-1..10). The logic could live in the tool container, as
`docker compose run --rm tools new-credential`.

**Acceptance criteria:**
- [ ] Each shape yields a credential whose first authorized request succeeds with no extra configuration
- [ ] Reusing an existing `--name` fails without modifying the existing registration
- [ ] CMS down → exit non-zero with "run start first"

**Verification:**
- [ ] Token plus a GET for each shape; POST a school with a SIS credential → 403 (not admin)

**Dependencies:** Task 12
**Files likely touched:** `ed-fi-api-v8/new-credential.{sh,ps1}`, `ed-fi-api-v8/init/new-credential.sh`
**Estimated scope:** M

## Task 14: Request files and smoke test

**Description:** Add three things:

- `http/smoke.http` with variables only (FR-TEST-1..3, 6..8): token,
  Discovery, a descriptor, write and read-back, paging (offset and cursor), a
  change-query extract, ETag If-Match, a deliberately invalid POST, and an
  assessment-style reference write marked "requires populated"
- `http/edorgs.http` for the baseline, as a template for adding more (FR-EDORG-1, 3, 6, 9, 10, 16)
- a scripted `smoke-test.{sh,ps1}` that runs the same path non-interactively,
  plus a consistency check that `edorgs.http` IDs match `baseline-edorgs.json`

Cursor paging needs a first token from a `limit=` response's `Next-Page-Token` header or from
`GET /data/ed-fi/{resource}/partitions`; `pageSize` alone returns 400 (spike Q8).

**Acceptance criteria:**
- [ ] `smoke-test` exits 0 on a fresh minimal start and a fresh populated start; non-zero when DMS is stopped
- [ ] `edorgs.http` re-run against a bootstrapped environment → no errors, no duplicates
- [ ] Populated-only requests fail with a recognizable message on minimal (FR-TEST-8)

**Verification:**
- [ ] Run the smoke test in both shells; run both `.http` files in VS Code REST Client

**Dependencies:** Task 13
**Files likely touched:** `ed-fi-api-v8/http/smoke.http`, `ed-fi-api-v8/http/edorgs.http`, `ed-fi-api-v8/smoke-test.{sh,ps1}`
**Estimated scope:** M

### Checkpoint D
- [ ] Walk through the flow for each of the three shapes on a clean volume: start → credential → smoke → first request

---

## Phase 5: Logging, docs, CI

## Task 15: Logging configuration

**Description:** Configure logging only, with no parsing:

- NGINX `log_format` as JSON, including request time, upstream time, status,
  path and query, correlation ID, and response size, written to `${LOG_DIR:-./logs}`
- DMS and CMS log levels from `.env`, with the correlation ID header enabled. DMS defaults to
  `Warning` (decision 11 in plan.md): at `Information`, Docker's log rotation discarded the error
  window of a populated load within minutes
- DMS/CMS file logs mounted into the same directory if the image supports it;
  otherwise document that they go through `docker logs` (FR-LOG-1..7, NFR-OBS-1)

**Acceptance criteria:**
- [ ] `logs/nginx/access.json` has one valid JSON object per request, and survives `down`
- [ ] Changing `LOG_LEVEL` changes DMS verbosity after restart
- [ ] The correlation ID sent by a client appears in both NGINX and DMS log lines

**Verification:**
- [ ] `jq` parses every line of the access log after a smoke run

**Dependencies:** Task 5 (can run in parallel with Phase 3/4)
**Files likely touched:** nginx template, `ed-fi-api-v8/compose.yml`, `.env.example`
**Estimated scope:** S

## Task 16: Participant documentation

**Description:** Write `ed-fi-api-v8/README.md` plus focused docs, covering:

- prerequisites and host resources for each template
- an ordered setup with the expected result at each step
- a table of integration shapes, with the template and claim set for each
- URLs and default credentials, labeled local-only
- certificate trust for .NET, JavaScript, and Python
- the bootstrap credential: its scope, warning, and removal
- the DataWarehouse claim set as a kit addition, with a feedback ask
- how to POST to the claim set reload endpoint to apply claim set changes immediately (FR-CLAIM-14, Task 18)
- the `/data/v3` caveat
- spike findings that need a sentence each: pgAdmin prompts for the database password; a Profile
  created while DMS runs isn't usable until DMS restarts (or up to 30 minutes); a school-scoped SIS
  credential still reads all schools; Swagger UI needs internet access (unpkg.com)
- the contents of the populated template
- what the logs capture
- privacy guidance
- troubleshooting
- known limitations
- the feedback path

Update the root `README.md` to link to it.

**Acceptance criteria:**
- [ ] Every FR-DOC item and every "Documentation SHALL" clause in the in-scope FRs is covered (a checklist lives in the PR)
- [ ] markdownlint passes

**Verification:**
- [ ] A fresh reader follows it on a clean host for both templates (FR-DOC-7)

**Dependencies:** Tasks 12–15, 18
**Files likely touched:** `ed-fi-api-v8/README.md`, `ed-fi-api-v8/docs/*.md`, `README.md`
**Estimated scope:** M

## Task 17: CI workflow

**Description:** A GitHub Actions workflow on PRs, using pinned action SHAs per the Ed-Fi allowlist. It
generates a certificate, runs `start.sh` on a clean runner with the minimal template, runs
`smoke-test.sh`, and uploads the logs as artifacts. A populated run happens nightly or on manual
dispatch. It also runs `shellcheck` and `PSScriptAnalyzer` over the scripts.

**Acceptance criteria:**
- [ ] The workflow is green on a PR; it fails when the smoke test is deliberately broken

**Verification:**
- [ ] A PR run

**Dependencies:** Task 14
**Files likely touched:** `.github/workflows/kit-smoke.yml`
**Estimated scope:** S

### Checkpoint E
- [ ] All in-scope PRD requirements are traced to a task or recorded as a known limitation
- [ ] Human review, then ready for participant distribution
