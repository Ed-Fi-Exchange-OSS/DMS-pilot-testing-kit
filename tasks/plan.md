# Implementation Plan: Ed-Fi API v8 Docker Compose Kit

## Overview

Build the default (v8-only) stack from
[the PRD](../docs/client-integration-pilot-PRD.md) as a standalone Compose
project in `ed-fi-api-v8/`. It contains NGINX, DMS, CMS, PostgreSQL, Swagger UI,
and PGAdmin. It also provides first-run initialization, the minimal and
populated templates, bootstrapping (the Ed-Fi Sandbox credential, the Data
Warehouse claim set, and the five-org hierarchy), credential provisioning,
lifecycle scripts, `.http` examples, and docs. The copied `dms-compose/`
directory is only a reference; it is git-ignored and will not ship.

**Out of scope for this plan (per request):** the `odsapi` profile and
everything tagged FR-COMP, the v7 halves of FR-BOOT-11, FR-CLAIM-13,
FR-TEST-5 and FR-EDORG-15, log parsing, and reports (FR-MET-\*,
FR-BOOT-12). FR-LOG work covers configuration only (levels, JSON format,
mounted directory), not analysis.

## What the existing `dms-compose/` tells us

- **Keep and slim down:** `postgresql.yml`, `published-dms.yml`,
  `published-config.yml`, `swagger-ui.yml` + `custom-swagger-ui/`, the
  OpenIddict key and client SQL in `setup-openiddict.ps1` and
  `Generate-OpenIddictKey-Insert.ps1`, and the CMS REST sequence in
  `configure-local-data-store.ps1` and `verify-school-year-data-stores.http`.
- **Drop:** Keycloak, Kafka/CDC, MSSQL, multi-tenancy, route qualifiers,
  plugins, OTLP, tmpfs, E2E env files, `tests/`, and the ~20k lines of
  PowerShell bootstrap modules. These fall under FR-PLAT-6.
- **It does not work standalone.** It depends on six files that live in the
  DMS source repo, including `Dms-Management.psm1`,
  `Package-Management.psm1`, `Claims.json`, and `AdditionalClaimsets/`.
- **`api-schema-tools` is required.** The DMS image does *not* deploy its
  relational schema. It returns 503 until
  `api-schema-tools ddl provision` has run, and that tool is currently built
  from DMS source with `dotnet publish`. *Resolved:* use the published `EdFi.Api.SchemaTools` NuGet package instead.
- **Templates are loaded through the API, not restored.** The current DMS
  flow runs BulkLoadClient over the Data Standard v5.2.0 XML. It loads
  `Descriptors/` for the minimal template, and adds `Samples/Sample XML` for
  the populated one. The old `DATABASE_TEMPLATE_PACKAGE` SQL-restore module is
  legacy and unused. Even the minimal template therefore needs a loader.
- **Swagger UI is hard-coded to `http://localhost:8080`.** It must be
  repointed to the NGINX routes.
- **No feature flags were found** for change queries, Profiles, ETags, or
  cursor paging. They appear to be always on; the spike verifies this.
- **`SISVendor` and `AssessmentVendor`** are never referenced in the copied
  files, so we don't yet know whether CMS embeds them. The spike verifies
  this. CMS claim-set *fragments* can only extend existing claim sets, so a
  new "DataWarehouse" set probably needs the CMS claim-set API.

## Architecture Decisions (proposed; please confirm)

1. **Location:** a single `ed-fi-api-v8/compose.yml`, with `ed-fi-api-v8/.env.example` as the only
   config surface (NFR-USE-3). One file with profiles, rather than many `-f` overlays, keeps
   "no manual Compose edits" (NFR-USE-2) true. Compose project name is fixed (`name: edfi-pilot`)
   and a project-scoped network replaces the external `dms` network.
2. **Initialization runs in containers, not in host scripts.** One-shot
   services, gated by `depends_on: condition: service_completed_successfully`,
   do the setup work:
   - OpenIddict key and client seeding
   - ApiSchema fetch
   - schema provisioning
   - data store registration
   - template load
   - bootstrap

   The host `.ps1`/`.sh` scripts then become thin wrappers around
   `docker compose` and print the results. This gives PowerShell/Bash parity
   (FR-LIFE-2/3, NFR-PORT-2) almost for free, because the logic exists once.
   Tooling image: a locally built `tools` image (see Decision 2), running POSIX `sh` scripts
   in `ed-fi-api-v8/init/`.
3. **Idempotency through state checks plus marker rows.** Each init step first
   checks for its target: key rows, clients, data store, the
   `dms.EffectiveSchema` table, and a kit marker such as a
   `kit.initialization` table recording the template and timestamp. It skips
   the step if the target already exists. This covers FR-LIFE-4, FR-TMPL-4 and
   FR-BOOT-4.
4. **Local-only binding.** Only NGINX publishes ports, on
   `127.0.0.1:${HTTPS_PORT:-443}` and `${HTTP_PORT:-80}`. PostgreSQL is
   optionally published on `127.0.0.1` for host DB tools. DMS and CMS are
   reachable only through NGINX (NFR-SEC-5, FR-ROUTE-1).
5. **Routes (configurable):**

   | Route | Target |
   | --- | --- |
   | `/api` | DMS, `PATH_BASE=api` |
   | `/config` | CMS |
   | `/swagger` | Swagger UI |
   | `/pgadmin` | PGAdmin |
   | `/data/v3/*` | rewritten to `/api/data/*` |

   DMS and CMS run with `UseForwardedHeaders=true` and trust the Compose
   network CIDR.
6. **Pinned artifacts in `.env.example`:**
   - DMS and CMS images, each as tag plus digest (see Decision 3)
   - ApiSchema package version (`1.0.335`)
   - Data Standard tag (`v5.2.0`)
   - NGINX, PostgreSQL, PGAdmin, and the `dotnet/sdk` base image by digest; SchemaTools and BulkLoadClient by version

   None of these uses `latest` (FR-PLAT-5, NFR-REL-3).
7. **Generated secrets.** The start script generates missing secrets into
   `.env` on first run: the CMS client secrets, the encryption keys, and the
   bootstrap credential. They are not shipped as fixed values (NFR-SEC-8).
   Runtime outputs go to the git-ignored `ed-fi-api-v8/.runtime/`, for example
   `bootstrap-credentials.json` and `credentials/<name>.json` (FR-BOOT-6).
8. **Single source of truth for the baseline hierarchy:**
   `ed-fi-api-v8/bootstrap/baseline-edorgs.json`. The bootstrap container
   POSTs its records. The `.http` file uses the same IDs as variables, and a
   check script diffs the two (FR-EDORG-14).
9. **Data Warehouse claim set** lives in
   `ed-fi-api-v8/bootstrap/claimsets/DataWarehouse.json`. It is read-only and
   version-controlled (FR-CLAIM-9). The mechanism for provisioning it (the CMS
   claim-set import API, or a Hybrid fragment) is decided by the spike in
   Task 1.

## Task List

Tasks are listed in detail in [todo.md](./todo.md). Summary:

### Phase 0: De-risk
- [ ] Task 1: Spike: prove standalone schema provisioning, claim sets, and seed loading

### Phase 1: Core stack (no ingress)
- [ ] Task 2: Compose skeleton and `.env.example` (PostgreSQL, CMS, DMS)
- [ ] Task 3: Identity init container (OpenIddict key and CMS system clients)
- [ ] Task 4: Schema and data store init containers, so DMS serves Discovery

### Checkpoint A: `docker compose up --wait` yields a healthy DMS with an authenticated GET

### Phase 2: Ingress
- [ ] Task 5: NGINX HTTPS ingress, certificate scripts, and forwarded headers
- [ ] Task 6: `/data/v3` rewrite toggle and opt-in rate limiting
- [ ] Task 7: Swagger UI and PGAdmin behind NGINX

### Checkpoint B: all participant URLs work over HTTPS, and Discovery returns https URLs

### Phase 3: Data and bootstrapping
- [ ] Task 8: Template loader, minimal template (descriptors) and first-init marker
- [ ] Task 9: Populated template, with fail-fast on missing source
- [ ] Task 10: Bootstrap credential and baseline education organization hierarchy
- [ ] Task 11: Data Warehouse claim set provisioning

### Checkpoint C: clean start on both templates, re-run creates no duplicates

### Phase 4: Participant tooling
- [ ] Task 12: Lifecycle scripts (start, stop, reset, bootstrap) in PowerShell and Bash
- [ ] Task 13: Credential provisioning scripts (by integration shape)
- [ ] Task 14: Request files and scripted smoke test (`smoke.http`, `edorgs.http`)

### Checkpoint D: under one hour from clone to credentialed call, for all three shapes

### Phase 5: Logging, docs, CI
- [ ] Task 15: Logging configuration (JSON NGINX access log, mounted log directory, levels)
- [ ] Task 16: Participant documentation
- [ ] Task 17: CI workflow: clean-volume start plus smoke test (NFR-MAINT-5)

### Checkpoint E: documentation followed on a clean host for both templates (FR-DOC-7)

## Parallelization

After Checkpoint A, Tasks 5–7 (ingress) and Tasks 8–11 (data) are independent. After Checkpoint C,
Tasks 13, 14, and 15 can run in parallel. Task 16 can start in outline form anytime, but is finished last.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| The SchemaTools version drifts from the DMS image, or the SDK base image is large (roughly 800 MB) | Med | Pin the version to match the DMS image (`8.0.1-alpha.0.164`); Task 1 verifies that it provisions the schema this DMS build expects, and whether a multi-stage build onto the smaller `dotnet/runtime` image works. |
| DMS has no populated template backup; loading through the API is slow | Med | Measure in Task 1 and Task 9, and document it (FR-TMPL-10). Later option: a `pg_dump` snapshot produced by CI and published per pilot round. |
| `SISVendor` / `AssessmentVendor` are not embedded in CMS | Med | Verified in Task 1. If missing, record it as a known limitation and escalate. The kit must not invent them (FR-FEAT-9, FR-CLAIM-7). |
| No CMS mechanism to *add* a claim set declaratively | Med | Task 1 evaluates the CMS `/v3/claimSets` create/import API; Task 11 uses whichever works and is idempotent. |
| Swagger UI and DMS generate `localhost:8080` URLs behind a proxy | Med | Forwarded headers and `PathBase` in Task 5; rewrite Swagger UI's spec URLs to be relative in Task 7. |
| Self-signed certificate friction (PRD-known) | Med | Certificate scripts plus per-ecosystem trust guidance (Task 5, Task 16). |
| Newly created CMS client returns 401 briefly (cache) | Low | Retry with backoff in the bootstrap and credential scripts. |
| Windows line endings breaking `sh` scripts in containers | Low | `.gitattributes` already forces LF; add a CI lint. |

## Decisions (answered 2026-09-28)

1. **Target directory:** `ed-fi-api-v8/`. Delete `dms-compose/` once the kit is complete.
2. **`api-schema-tools`:** use the `EdFi.Api.SchemaTools` .NET global tool, version
   `8.0.1-alpha.0.164`, from the Ed-Fi Azure Artifacts NuGet feed. It installs with:

   ```shell
   dotnet tool install edfi.api.schematools --global --version 8.0.1-alpha.0.164 \
     --source https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/index.json
   ```

   The kit ships a small `ed-fi-api-v8/tools/Dockerfile`, built locally by Compose (`build:`). It
   starts from a digest-pinned `mcr.microsoft.com/dotnet/sdk` image, installs SchemaTools, and adds
   the BulkLoadClient needed for Task 8 plus `curl`, `jq`, and `psql`. Because the tool is installed
   when the image is built, not on every startup, first build is the only time the feed is
   contacted. This one image replaces the plain alpine tool image first proposed in Architecture Decision 2. The
   participant needs no host .NET SDK (NFR-PORT-2).
3. **Images:**
   - CMS: `edfialliance/ed-fi-api-configuration-service:pre@sha256:57c0afed65d349ee1ecedd732a76b03c4341ba8623faa4df87151b1b99a382cc`
   - DMS: `edfialliance/ed-fi-api:8.0.1-alpha.0.164@sha256:f0c467be0f113096b3cae79802146de33da9b1efb218a1f3907ad1a5f14f27ea`
4. **Initialization in containers:** approved (Architecture Decision 2).
5. **Baseline education organization IDs:**

   | Organization | ID |
   | --- | --- |
   | SEA | `99` |
   | LEA | `9900` |
   | Elementary school | `990001` |
   | Middle school | `990002` |
   | High school | `990003` |

6. **Data Warehouse claim set:** `Read` on literally everything:
   - all resources
   - all descriptors
   - education organizations
   - people, including students, staff, and contacts

   It is not scoped by education organization: it uses a no-further-authorization-style strategy
   on Read. It grants no Create, Update, or Delete. Warehouse credentials therefore don't need
   education organization IDs, so FR-CRED-9 doesn't apply to them.
7. **Swagger UI:** reuse the copied `custom-swagger-ui` for now. The published Ed-Fi Swagger UI image
   is still being researched and may replace it later.

## Remaining Open Questions

- None blocking. Task 1 will surface anything new.
