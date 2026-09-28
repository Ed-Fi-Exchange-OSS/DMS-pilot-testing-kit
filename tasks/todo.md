# Task List: Ed-Fi API v8 Docker Compose Kit

See [plan.md](./plan.md) for context, decisions, risks, and open questions. All paths are relative to
the repository root; new work lives in `ed-fi-api-v8/`.

Common verification command (defined in Task 12, used informally before then):
`docker compose -f ed-fi-api-v8/compose.yml --env-file ed-fi-api-v8/.env up -d --wait`

## Status (2026-09-28)

Docker isn't available in the sandbox yet, so the following files were drafted and checked without a
Docker daemon. They are uncommitted and still need a real `docker compose up` run.

- Task 1 (partial): SchemaTools and BulkLoadClient findings are in `ed-fi-api-v8/tools/README.md`
- Task 4 (partial): `ed-fi-api-v8/tools/Dockerfile`
- Tasks 5, 6, 15 (NGINX parts): `ed-fi-api-v8/nginx/`, `ed-fi-api-v8/ssl/`
- Task 7: `ed-fi-api-v8/swagger-ui/`, `ed-fi-api-v8/pgadmin/`
- Task 2 (static checks only): `compose.yml` plus `compose.{core,init,ingress}.yml`, `.env.example`,
  `.gitignore`. `docker compose config` passes, and every pinned image digest exists in its registry.
  Still to verify: `up -d db config` reaching healthy.

The ingress, Swagger UI, PGAdmin, and tools entries from the READMEs are now wired into the compose files.

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
- [ ] `tasks/spike-notes.md` records each answer with the command or endpoint used as evidence
- [ ] A working, pinned container recipe for `EdFi.Api.SchemaTools` that provisions a schema DMS accepts
- [ ] Measured wall time and DB size for the minimal and populated loads

**Verification:**
- [ ] Manual check: a hand-run stack returns 200 for an authenticated `GET /api/data/ed-fi/schools`

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
- [ ] `docker compose up -d db config` → both healthy

**Dependencies:** Task 1
**Files likely touched:** `ed-fi-api-v8/compose.yml`, `ed-fi-api-v8/.env.example`, `.gitignore`
**Estimated scope:** S

## Task 3: Identity init container

**Description:** A one-shot `init-identity` service. Before CMS starts, it creates `dmscs.OpenIddictKey`
with a locally generated RSA key. After CMS is healthy, it inserts the `DmsConfigurationService`,
`CMSReadOnlyAccess`, and admin clients. Re-runs are idempotent. Port the SQL from `setup-openiddict.ps1`
to `sh`.

**Acceptance criteria:**
- [ ] Clean start: CMS `/connect/token` issues an admin token
- [ ] Second `up` makes no new key or client rows and exits 0
- [ ] Secrets come from `.env`, never hard-coded

**Verification:**
- [ ] `docker compose up --wait` twice; `SELECT count(*)` from the key and application tables is unchanged

**Dependencies:** Task 2
**Files likely touched:** `ed-fi-api-v8/compose.yml`, `ed-fi-api-v8/init/identity.sh`, `ed-fi-api-v8/init/lib.sh`
**Estimated scope:** M

## Task 4: Schema and data store init

**Description:** One-shot services that:

1. fetch the pinned DS 5.2 ApiSchema package into a shared volume
2. register the single data store in CMS if absent
3. run `EdFi.Api.SchemaTools` (`ddl provision`) if `dms.EffectiveSchema` is absent

DMS mounts the ApiSchema volume (`USE_API_SCHEMA_PATH=true`,
`SCHEMA_PACKAGES=[]`) and depends on all three completing.

**Acceptance criteria:**
- [ ] Clean `up --wait` → DMS healthy; `GET /api` Discovery returns 200 with DS 5.2
- [ ] Re-run doesn't re-register the data store or re-provision
- [ ] Failure of any init step makes `up --wait` fail and names the service

**Verification:**
- [ ] Manual: create a vendor and application via CMS by hand, get a token, and `GET` a descriptor list → 200

**Dependencies:** Task 3
**Files likely touched:** `ed-fi-api-v8/tools/Dockerfile`, `ed-fi-api-v8/compose.yml`, `ed-fi-api-v8/init/api-schema.sh`, `ed-fi-api-v8/init/datastore.sh`, `ed-fi-api-v8/init/provision-schema.sh`
**Estimated scope:** M

### Checkpoint A
- [ ] Clean-volume `up --wait` succeeds; restart preserves data; second `up` is a no-op
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
- [ ] `http://` → 301 to https; stopping DMS returns 503, not 502 (FR-ROUTE-9)
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
- [ ] Any feature that can't be enabled is written down for the known-limitations doc (FR-FEAT-9b)

---

## Phase 3: Data and bootstrapping

## Task 8: Template loader, minimal template, and first-init marker

**Description:** Add an `init-template` one-shot service that runs BulkLoadClient in a pinned .NET
runtime container. It loads the pinned DS v5.2.0 `Descriptors/` XML (plus SchoolYearType via REST),
using a SeedLoader credential created through CMS. `DATABASE_TEMPLATE=minimal|populated` in `.env`
selects the template. A marker table records the template and completion. If the marker exists, the
service skips; if the marker disagrees with `.env`, it warns (FR-TMPL-4/5).

**Acceptance criteria:**
- [ ] Clean start with the default → descriptor endpoints are populated; no education organizations exist
- [ ] Restart does not reload; changing `DATABASE_TEMPLATE` without a reset prints "requires reset" and does not reload
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

**Acceptance criteria:**
- [ ] Clean minimal start → 5 education organizations exist; credentials file written with IDs
- [ ] Re-run → no duplicate vendor, application, or education organizations; missing records are recreated (FR-BOOT-4/5)
- [ ] Works on the populated template too, with IDs that don't collide (FR-EDORG-8)

**Verification:**
- [ ] `GET /api/data/ed-fi/schools?localEducationAgencyId=<LEA>` → 3 schools

**Dependencies:** Task 8 (descriptors present)
**Files likely touched:** `ed-fi-api-v8/init/bootstrap.sh`, `ed-fi-api-v8/bootstrap/baseline-edorgs.json`, `ed-fi-api-v8/compose.yml`
**Estimated scope:** M

## Task 11: Data Warehouse claim set

**Description:** Add `bootstrap/claimsets/DataWarehouse.json`, with Read on literally everything: all resources,
descriptors, education organizations, and people. Read is not scoped by education organization
(no-further-authorization-style), and the set grants no Create, Update, or Delete. Provision it idempotently during bootstrap, using the mechanism chosen in Task 1.
Leave the standard claim sets untouched (FR-CLAIM-5..9).

**Acceptance criteria:**
- [ ] `GET /config/v3/claimSets` lists `DataWarehouse`; its authorization metadata shows Read only
- [ ] A DataWarehouse credential with no education organization IDs can GET every resource, including students outside the baseline organizations on the populated template; POST, PUT, and DELETE return 403
- [ ] Standard claim sets are byte-identical before and after (export diff)

**Verification:**
- [ ] Scripted check in the smoke test (Task 14)

**Dependencies:** Task 10
**Files likely touched:** `ed-fi-api-v8/bootstrap/claimsets/DataWarehouse.json`, `ed-fi-api-v8/init/bootstrap.sh`
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
| `--edorg-ids` | Optional. Defaults to the baseline education organizations (`99`, `9900`, `990001`–`990003`) on minimal, or the sample LEA and schools on populated. Warehouse credentials don't need it. |

The script uses the bootstrap admin client against CMS. It prints and saves the key and secret to
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
- DMS and CMS log levels from `.env`, with the correlation ID header enabled
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
- the `/data/v3` caveat
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

**Dependencies:** Tasks 12–15
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
