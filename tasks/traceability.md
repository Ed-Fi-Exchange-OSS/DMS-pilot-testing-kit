# Checkpoint E: PRD traceability

Date: 2026-10-05. Branch `dms-compose`, through `fc5cbc0`. Decisions D1–D12 applied 2026-10-06.

This file traces every requirement ID in
[`docs/client-integration-pilot-PRD.md`](../docs/client-integration-pilot-PRD.md) (180 bullets) to
a task in [todo.md](./todo.md), a CI run, a host QA run, or the code itself. The 2026-10-06 PRD
fixes removed FR-TMPL-6 (D1) and renumbered the second `FR-FEAT-9` to `FR-FEAT-10` (D2). FR-TMPL-6
keeps a row below for reference but isn't counted. It closes the first Checkpoint E item: "All
in-scope PRD requirements are traced to a task or recorded as a known limitation."

It was written in a sandbox with no Docker daemon. Nothing below was run against a live stack in
this pass. "Verified" means a checked todo.md item, a green CI run, a host QA record
([qa.D.md](./qa.D.md)), or the spike, together with the code that implements it. Where the only live
evidence predates the current image pins, the row says so.

**Image note.** The spike and Tasks 1–11 ran against DMS `8.0.1-alpha.0.164`. Commit `f356d16`
moved DMS and CMS to `8.1.0-beta1` (`ed-fi-api-v8/.env.example:65,70`) before the Checkpoint D host
QA and the CI runs. Evidence that only exists from the spike (Profiles, the Discovery `https` URLs,
DataWarehouse write 403s, the 349-endpoint sweep) has not been repeated on `8.1.0-beta1`.

## Legend

| Status | Meaning |
| --- | --- |
| Verified | Implemented, and a checked acceptance item, CI run, host QA, or a static check in this pass covers it |
| Implemented, unverified | Code or docs exist, but the todo.md item is unchecked or the only evidence is from the sandbox or an older image. The row names the host check that would close it |
| Known limitation | Can't or won't be met as written; the row says why |
| Out of scope | Excluded by [plan.md](./plan.md) lines 14–21 |
| Gap | In scope, and nothing implements it |
| Removed | Deleted from the PRD; kept for reference and not counted |

## Summary

| Status | Count |
| --- | --- |
| Verified | 133 |
| Implemented, unverified | 17 |
| Known limitation | 3 |
| Out of scope | 27 |
| Gap | 0 |
| **Total** | **180** |

No Gaps remain. NFR-PORT-3, the former Gap, is a known limitation by decision D5: no RAM or CPU
figure is published. See "Decisions (resolved 2026-10-06)" for every decision and the rows it
changed.

Path shorthand below: `kit/` = `ed-fi-api-v8/`, `todo` = `tasks/todo.md`, `qa.D` = `tasks/qa.D.md`,
`spike` = `tasks/spike-notes.md`, `plan` = `tasks/plan.md`. "CI" = `.github/workflows/kit-smoke.yml`,
run 37238116552 (minimal, PR #5) and dispatch run 37341471550 (populated), per `todo:58-62`.
`access.json` = `kit/logs/nginx/access.json`, a git-ignored log produced on the host (786 lines,
2026-09-28 to 2026-10-05).

---

## 3.1 Environment Lifecycle

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-LIFE-1 | One documented start command; only `.env` editing needed | Verified | `kit/start.sh`, `kit/start.ps1`; creates `.env` itself (`kit/scripts/lib.sh:270-293`). Task 12 host QA (`todo:529-534`), CI |
| FR-LIFE-2 | Equivalent PowerShell and Bash scripts | Verified | `kit/{start,stop,reset,bootstrap,new-credential,smoke-test}.{sh,ps1}`; `qa.D` Part 2. PowerShell 7 is required; 5.1 is unsupported (D8) |
| FR-LIFE-3 | Same parameters and outcomes; one documented workflow | Verified | `qa.D` T12-a (`qa.D:233-247`); README "Bash and PowerShell commands behave identically" (`kit/README.md:90-91`) |
| FR-LIFE-4 | Start is idempotent on a running stack | Verified | `todo:530`, `qa.D` 1.2 |
| FR-LIFE-5 | Stop preserves data | Verified | `kit/stop.sh:45` (`compose stop`); `qa.D` 1.8 (credential still works after stop/start) |
| FR-LIFE-6 | Labelled destructive reset removes volumes | Verified | `kit/reset.sh:63-93` (confirmation, `down -v`, `.runtime/` cleanup); `todo:531`; CI teardown |
| FR-LIFE-7 | Success only after API ready and bootstrap done; waits on health | Verified | `up -d --build --wait` (`kit/start.sh:106`); `swagger-ui` depends on `init-bootstrap` completing (`kit/compose.ingress.yml:74-76`); CI |
| FR-LIFE-8 | Success prints URLs, template, next step | Verified | `kit/start.sh:111-124`; `qa.D` 1.1 |
| FR-LIFE-9 | Failure exits non-zero, names the failed service and its logs | Implemented, unverified | `kit/scripts/lib.sh:477-571`. Only tested against a fake `docker` (`todo:233-235`). Host check: force an init failure (see "Unchecked acceptance items", T4-233) |
| FR-LIFE-10 | Default start doesn't start the comparative stack | Verified | No `odsapi` profile exists; the only profile is `tools` (`kit/compose.init.yml:37-39`). True by construction |

## 3.2 Platform Composition and Data Standard

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-PLAT-1 | Default stack has DMS and CMS | Verified | `kit/compose.core.yml:38-174`; CI |
| FR-PLAT-2 | Configured for DS 5.2 | Verified | `ClaimsOptions__DataStandardVersion: "5.2"` (`kit/compose.core.yml:58`); Discovery DS 5.2, no TPDM (`todo:229`) |
| FR-PLAT-3 | Minimal template by default | Verified | `DATABASE_TEMPLATE=minimal` (`kit/.env.example:92`); CI minimal smoke `descriptor-list` step |
| FR-PLAT-4 | PostgreSQL only | Verified | `kit/compose.core.yml:16-36`; no other engine in any compose file |
| FR-PLAT-5 | Every image pinned via `.env` | Verified | Static check this pass: DMS, CMS, PostgreSQL, NGINX, PGAdmin, and both .NET bases are tag plus digest (`kit/.env.example:65-81`); `swagger-ui` reuses `NGINX_IMAGE`, `init-api-schema` reuses `DMS_IMAGE`. Caveat: tools-image apt packages float (`kit/tools/Dockerfile:100-103`). `todo:134` can be ticked |
| FR-PLAT-6 | Minimal service inventory | Verified | 6 long-running services plus one-shot inits (`kit/compose*.yml`); Keycloak, Kafka, MSSQL dropped (`plan:30-32`) |

## 3.3 Database Template Selection

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-TMPL-1 | Exactly two templates; populated = DS 5.2 sample data | Verified | `kit/init/template.sh:61-66`; `todo:379`; CI populated run |
| FR-TMPL-2 | One `.env` setting, minimal default | Verified | `kit/.env.example:87-92` |
| FR-TMPL-3 | Same templates and one setting for v8 and the comparative stack | Out of scope | Needs the `odsapi` profile (`plan:14-21`, confirmed by D10). The v8 half is FR-TMPL-1/2 |
| FR-TMPL-4 | Template applies at first init only; no silent reinit | Verified | Marker table (`kit/init/template.sh:88-125`); `todo:350`. `start` prints the template actually loaded (`kit/scripts/lib.sh:592-600`) |
| FR-TMPL-5 | Docs: switching needs reset; reset is enough | Verified | `kit/README.md:437-441`, `kit/docs/troubleshooting.md:112-132`; Checkpoint C passed on host (`todo:32`) |
| FR-TMPL-6 | Docs recommend a template per shape | Removed | Removed from the PRD on 2026-10-06 (D1); it contradicted FR-TMPL-9. The per-shape recommendation (assessment → populated) is still required by FR-DOC-8 and covered there |
| FR-TMPL-7 | Populated with missing/unreadable source fails, no fallback | Implemented, unverified | Content pins and `die` on download, extract, and hash mismatch (`kit/init/template.sh:139-213`). `todo:380` unchecked. Host check in T9-380 below |
| FR-TMPL-8 | Docs describe populated contents | Verified | `kit/README.md:375-386` (orgs, 960 students, resource counts, from `spike:617`) |
| FR-TMPL-9 | Populated usable for write testing | Verified | Smoke `assessment-write` PASS on populated (`qa.D` Part 3); `http/smoke.http` step 10 |
| FR-TMPL-10 | Docs state download, disk, startup cost | Verified | `kit/README.md` "The populated template", `kit/.env.example:87-91`. The README publishes the spike's figures by decision D9; the host's ~200 s populated `up` and the unmeasured volume size (`todo:381-382`) don't change them |

## 3.4 API Feature Availability

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-FEAT-1 | All DS 5.2 Resources and Descriptors endpoints | Verified | `ApiSchema.json` hash pin (`kit/.env.example:69`) verified by `init-api-schema`; EffectiveSchema hash (`todo:230`). The 349-endpoint sweep (`spike:647-648`) was on the older image only |
| FR-FEAT-2 | Discovery API | Verified | Smoke step 2 (`kit/init/smoke-test.sh:193-201`); CI |
| FR-FEAT-3 | XSD, OpenAPI, Swagger UI | Verified | `todo:236` (metadata 200); `todo:307-308` (Swagger UI loads specs, "Try it out" works, host browser 2026-10-04) |
| FR-FEAT-4 | Change queries | Verified | Smoke step 7 (`kit/init/smoke-test.sh:286`); CI |
| FR-FEAT-5 | Profiles | Implemented, unverified | On by default, with no flag (`spike:504-508`, older image). Not in the smoke test; Checkpoint B unchecked (`todo:320`). Host check in CP-B-320 below |
| FR-FEAT-6 | ETag | Verified | Smoke step 8, If-Match plus stale 412 (`kit/init/smoke-test.sh:308`); CI |
| FR-FEAT-7 | Limit/offset paging | Verified | Smoke step 5 (`kit/init/smoke-test.sh:253`); CI |
| FR-FEAT-8 | Cursor paging | Verified | Smoke step 6 (`kit/init/smoke-test.sh:268`); CI |
| FR-FEAT-9 | Standard claim sets unmodified; kit may add | Implemented, unverified | `init-claimsets` refuses to touch a system-reserved set (`kit/init/claimsets.sh:224-230`) and only imports files in `kit/bootstrap/claimsets/`. Export diff `todo:449` unchecked; see T11-449 |
| FR-FEAT-10 | Features that can't be enabled are listed as known limitations | Implemented, unverified | Spike found every 3.4 feature on (`spike:540`); Profiles not rechecked on `8.1.0-beta1`. `todo:321` unchecked. This file's "Known limitations" section closes it once Profiles is rechecked |

## 3.5 Environment Bootstrapping

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-BOOT-1 | Startup creates `EdFiSandbox` bootstrap credential | Verified | `kit/init/bootstrap.sh:50-53,106-177`; `todo:411` |
| FR-BOOT-2 | Bootstrap creates the baseline hierarchy | Verified | `kit/init/bootstrap.sh:260-319`; `todo:411,416` |
| FR-BOOT-3 | Bootstrap finishes before startup reports success | Verified | `kit/compose.ingress.yml:74-76` plus `--wait`; CI |
| FR-BOOT-4 | Idempotent: no duplicate credentials or orgs | Verified | `todo:412`; `qa.D` 1.8 |
| FR-BOOT-5 | Populated: create only missing baseline records | Verified | GET-before-POST per record (`kit/init/bootstrap.sh:277-310`); `todo:412` (deleted school recreated). On populated, smoke step 4 writes against `990002`/`990003`, so they exist (CI populated run, `qa.D` Part 3) |
| FR-BOOT-6 | Report and persist key, secret, org IDs | Verified | `.runtime/bootstrap-credentials.json`, mode 600 (`kit/init/bootstrap.sh:193-245`); `todo:411` |
| FR-BOOT-7 | Labelled administrative; not for integration testing | Verified | File `warning` field (`kit/init/bootstrap.sh:204-207`); `start` output (`kit/start.sh:118-120`); `kit/README.md:289-310` |
| FR-BOOT-8 | Docs state its permissions and warn | Verified | `kit/README.md:300-305`; `kit/docs/credentials-and-claim-sets.md:82` |
| FR-BOOT-9 | Bootstrap failure fails startup, naming the step | Implemented, unverified | Step names on every `die` (`kit/init/bootstrap.sh:39-46`), listed in `kit/docs/troubleshooting.md:134-148`. No host run with a forced bootstrap failure; the start-script report is unverified (FR-LIFE-9) |
| FR-BOOT-10 | Bootstrap runnable standalone | Verified | `kit/bootstrap.sh`, `kit/bootstrap.ps1`; `qa.D` 1.8 |
| FR-BOOT-11 | Same bootstrap on the comparative stack | Out of scope | `plan:15-16` |
| FR-BOOT-12 | Bootstrap records excluded from metrics | Out of scope | `plan:16-17` (FR-BOOT-12 named) |
| FR-BOOT-13 | Docs explain deleting/disabling the bootstrap credential | Implemented, unverified | `kit/docs/credentials-and-claim-sets.md:144-165`. Reset path verified; the `DELETE /v3/applications/{id}` path is marked unverified in the doc itself (`:163-165`) and in `kit/init/lib.sh:330` |
| FR-BOOT-14 | Bootstrap also provisions DataWarehouse | Verified | `init-claimsets` in the pre-DMS chain (`kit/compose.core.yml:163-166`, `kit/compose.init.yml:150-171`); first DataWarehouse request 200 (`todo:448`) |

## 3.6 Claim Sets and Authorization

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-CLAIM-1 | Bootstrap uses `EdFiSandbox` | Verified | `kit/init/bootstrap.sh:53`; `todo:411` |
| FR-CLAIM-2 | Participant credentials never use the bootstrap claim set | Verified | `--shape` defaults never pick `EdFiSandbox` (`kit/init/new-credential.sh:225-230`). `--claim-set` accepts any existing set, `EdFiSandbox` included (`:232-247`); the override stays unrestricted by design (D6) |
| FR-CLAIM-3 | SIS → `SISVendor` | Verified | `kit/init/new-credential.sh:226`; `qa.D` 1.4 |
| FR-CLAIM-4 | Assessment → `AssessmentVendor` | Verified | `kit/init/new-credential.sh:227`; `qa.D` 1.4 |
| FR-CLAIM-5 | Kit provisions a read-all DataWarehouse set | Verified | `kit/bootstrap/claimsets/DataWarehouse.json` (14 roots); host import with no warnings (`todo:22-23`); warehouse first requests 200 on both templates (`qa.D` 1.4, Part 3). Full sweep only in the spike |
| FR-CLAIM-6 | DataWarehouse grants read only | Implemented, unverified | File grants only `Read` and `ReadChanges` (checked with `jq` this pass). The live 403-on-write proof is spike-only (`spike:641-644`); `todo:445-447` unchecked |
| FR-CLAIM-7 | No standard claim set modified | Implemented, unverified | Same as FR-FEAT-9 |
| FR-CLAIM-8 | DataWarehouse provisioning part of bootstrap, idempotent, fails with a message | Verified | Name check plus normalized diff before import (`kit/init/claimsets.sh:196-253`); re-runs clean (Checkpoint C, `todo:32`). The failure message path is code-only |
| FR-CLAIM-9 | DataWarehouse definition in version control | Verified | `kit/bootstrap/claimsets/DataWarehouse.json`, imported as-is |
| FR-CLAIM-10 | Claim set is a parameter, defaults by shape, rejects unknown | Implemented, unverified | `kit/init/new-credential.sh:221-247`. The default is verified; rejecting an unknown name was never run on the host. Host check under T11 below |
| FR-CLAIM-11 | Docs: claim set per shape; DataWarehouse is a kit addition | Verified | `kit/README.md:69-73,324-328`; `kit/docs/credentials-and-claim-sets.md:80-87` |
| FR-CLAIM-12 | Docs invite DataWarehouse feedback | Verified | `kit/README.md:324-328,491-492` |
| FR-CLAIM-13 | Equivalent claim sets on the comparative stack | Out of scope | `plan:15-16` |
| FR-CLAIM-14 | Docs: POST to the reload endpoint | Verified | `kit/README.md:330-357`; `kit/http/claimset-test.http`; `todo:487-490` |

## 3.7 Credential Provisioning

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-CRED-1 | Script registers CMS client and makes credentials | Verified | `kit/new-credential.{sh,ps1}`, `kit/init/new-credential.sh`; `todo:558,563` |
| FR-CRED-2 | Prints key and secret; says non-recoverable | Verified | `kit/init/new-credential.sh:439-444`; `kit/README.md:189-200` |
| FR-CRED-3 | Re-runnable; never overwrites a registration | Verified | `kit/init/new-credential.sh:174-185`; `todo:559`, `qa.D` 1.5 |
| FR-CRED-4 | Associates claim set and orgs; docs say how to change | Verified | `kit/docs/credentials-and-claim-sets.md:16-61`. Docs cover choosing orgs at creation (`--edorg-ids`), not editing an existing credential |
| FR-CRED-5 | Docs: get a token | Verified | `kit/README.md:225-231`; `kit/http/smoke.http` step 1 |
| FR-CRED-6 | Fails clearly when CMS isn't ready | Verified | `kit/init/new-credential.sh:164`; `todo:560`, `qa.D` 1.6 |
| FR-CRED-7 | Supports warehouse credentials | Verified | `--shape warehouse` (`kit/init/new-credential.sh:228,269-271`); `qa.D` 1.4 |
| FR-CRED-8 | Populated: scoped to template orgs; first request works | Verified | Default `[255901]`, the sample LEA (`kit/init/new-credential.sh:272-274`); `qa.D` Part 3. Not scoped to the ESC, PSI, community provider, or the baseline hierarchy |
| FR-CRED-9 | Minimal: scoped to the bootstrapped hierarchy | Verified | Default SEA `99` (`kit/init/new-credential.sh:260-277`); SEA reaches LEA and schools (`spike:450-469`); `qa.D` 1.4 |
| FR-CRED-10 | Org IDs optional, overridable | Implemented, unverified | `--edorg-ids` (`kit/init/new-credential.sh:280-291`). Optional is verified; the override was never run on the host |

## 3.8 Routing and Request Handling

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-ROUTE-1 | NGINX single ingress, configurable prefixes | Verified | Only NGINX publishes ports (`kit/compose.ingress.yml:30-33`) besides loopback PostgreSQL; `DMS_PATH_BASE`/`CMS_PATH_BASE` (`kit/nginx/templates/default.conf.template:143-167`); smoke runs through NGINX |
| FR-ROUTE-2 | HTTPS from mounted certs; HTTP → HTTPS | Verified | `kit/nginx/templates/default.conf.template:86-112`; smoke `http-redirect` step fails on a missing 301 (`kit/init/smoke-test.sh:540-547`); CI. 301s in `access.json` on 2026-10-04 and 10-05 |
| FR-ROUTE-3 | Cert script; trust docs for .NET, JS, Python | Verified | `kit/ssl/generate-certificate.{sh,ps1}` (CI uses the `.sh`); `kit/README.md:263-287` |
| FR-ROUTE-4 | Forwarded headers for correct absolute URLs | Implemented, unverified | `kit/nginx/templates/snippets/kit-proxy.conf.template:18-24`; `UseForwardedHeaders` (`kit/compose.core.yml:52-54,96-97`). `https` Discovery URLs seen only in the spike (`spike:337-347`); `todo:266` unchecked |
| FR-ROUTE-5 | `/data/v3` rewrite, on by default | Verified | `kit/nginx/entrypoint.d/40-kit-features.sh:114-125`; smoke `data-v3-rewrite` step (`kit/init/smoke-test.sh:517-538`); CI. Body equality only in the spike (`spike:682`) |
| FR-ROUTE-6 | Rewrite disableable with one setting | Implemented, unverified | `DATA_V3_REWRITE_ENABLED` (`kit/nginx/entrypoint.d/40-kit-features.sh:126-141`). No `false` run anywhere; `todo:286` unchecked |
| FR-ROUTE-7 | Docs: `/data/v3` is an affordance; ask about reliance | Verified | `kit/README.md:249-253,493` |
| FR-ROUTE-8 | Rate limiting available, off, configurable | Implemented, unverified | `kit/nginx/entrypoint.d/40-kit-features.sh:143-165`; off by default (`kit/.env.example:45`). Enabled path never run; no 429 in `access.json`; `todo:287` unchecked |
| FR-ROUTE-9 | Clear 503 when a backend is down | Verified | `@kit_unavailable` (`kit/nginx/templates/default.conf.template:135,217-230`); JSON body seen in `spike:684`; `service=dms status=503` lines in `access.json` on 2026-10-04 (template unchanged since) |

## 3.9 Comparative ODS/API Testing

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-COMP-1 | ODS/API 7.3.2 plus Admin API 2.3.2 in an `odsapi` profile | Out of scope | `plan:14-15`; `kit/README.md:455-457` |
| FR-COMP-2 | Comparative route through the same NGINX | Out of scope | `plan:14-15` |
| FR-COMP-3 | Comparative stack DS 5.2, same template | Out of scope | `plan:14-15` |
| FR-COMP-4 | Own DB service and volume | Out of scope | `plan:14-15` |
| FR-COMP-5 | Admin API credentialing per FR-CRED | Out of scope | `plan:14-15` |
| FR-COMP-6 | Symmetric reporting | Out of scope | `plan:14-17` |
| FR-COMP-7 | Docs: comparative is optional, with its cost | Out of scope | `plan:14-15` |

## 3.10 Logging

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-LOG-1 | Logging deliberately captures outcomes, errors, timing | Verified | `kit_json` log format (`kit/nginx/templates/default.conf.template:50-74`); DMS `Warning` default with rationale (`plan:264-265`); Task 15 (`todo:616-625`) |
| FR-LOG-2 | Log levels from `.env` | Verified | `DMS_LOG_LEVEL`/`CMS_LOG_LEVEL` (`kit/compose.core.yml:75,144`); host check passed (`todo:626`) |
| FR-LOG-3 | API and NGINX logs to a configurable host directory | Known limitation | NGINX: yes, `${LOG_DIR}` bind mount (`kit/compose.ingress.yml:38`). DMS and CMS: only `docker compose logs`, documented in `kit/README.md` "Logs". Accepted as a known limitation for now (D3) |
| FR-LOG-4 | Machine-parseable logs | Verified | One JSON object per line; `jq -e` over the host log (`todo:616-625,654-661`) |
| FR-LOG-5 | Correlation ID per request | Verified | `kit/nginx/templates/default.conf.template:19-22`, `kit/compose.core.yml:102`; fresh NGINX and DMS pairing on host (`todo:636-637,80-81`) |
| FR-LOG-6 | Docs state what logs capture | Verified | `kit/README.md:397-413,415-425` |
| FR-LOG-7 | Read activity logged with paths, query, counts, durations | Verified | `args`, `total_count` (only when the client asks for `totalCount=true`), `request_time` (`kit/nginx/templates/default.conf.template:59-71`) |

## 3.11 Metrics and Reporting

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-MET-1 | Scripted log parsing makes a run report | Out of scope | `plan:16-17`; `kit/README.md:458-460` |
| FR-MET-2 | Report: error count | Out of scope | `plan:16-17` |
| FR-MET-3 | Report: landed record count | Out of scope | `plan:16-17` |
| FR-MET-4 | Report: end-to-end duration | Out of scope | `plan:16-17` |
| FR-MET-5 | Report: errors by status and resource | Out of scope | `plan:16-17` |
| FR-MET-6 | Report: environment configuration | Out of scope | `plan:16-17` |
| FR-MET-7 | Report: human- and machine-readable files | Out of scope | `plan:16-17` |
| FR-MET-8 | Reporting doesn't alter logs | Out of scope | `plan:16-17` |
| FR-MET-9 | No transmission of results or telemetry | Out of scope | `plan:16-17`. The kit sends no telemetry, but there is no reporting to test |
| FR-MET-10 | Docs: how to submit the report | Out of scope | `plan:16-17` |
| FR-MET-11 | Report separates writes from reads | Out of scope | `plan:16-17` |
| FR-MET-12 | Read-side report metrics | Out of scope | `plan:16-17` |
| FR-MET-13 | Report works for any shape without a mode | Out of scope | `plan:16-17` |
| FR-MET-14 | Report excludes kit-generated activity | Out of scope | `plan:16-17` |

## 3.12 Smoke Test and Request Examples

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-TEST-1 | `.http` with token, Discovery, descriptor, write, read-back, paging | Verified | `kit/http/smoke.http` steps 1–6; `qa.D` 1.10 |
| FR-TEST-2 | Usable right after start; variables, not secrets | Verified | `@key`/`@secret` variables (`kit/http/smoke.http:31-33`); `qa.D` 1.10 |
| FR-TEST-3 | At least one deliberately invalid request | Verified | `kit/http/smoke.http` step 9; smoke step 9 |
| FR-TEST-4 | Scripted smoke test, non-zero on failure | Verified | `kit/smoke-test.{sh,ps1}`; `todo:585`; CI deliberately broken run 37378594249 fails (`todo:752-755`) |
| FR-TEST-5 | Comparative-route examples | Out of scope | `plan:15-16` |
| FR-TEST-6 | Full paged extract and change-query extract | Verified | `kit/http/smoke.http` steps 5–7 |
| FR-TEST-7 | Assessment-style write referencing existing student and org | Verified | `kit/http/smoke.http` step 10; `qa.D` Part 3 |
| FR-TEST-8 | Template-dependent examples say so and fail recognizably | Verified | "requires populated" labels (`kit/http/smoke.http:175-214`); `todo:587` |

## 3.13 Sample Education Organization Hierarchy

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-EDORG-1 | `.http` creates the baseline; usable as a template | Verified | `kit/http/edorgs.http`; `qa.D` 1.10 |
| FR-EDORG-2 | Exactly SEA, LEA, three schools | Verified | `kit/bootstrap/baseline-edorgs.json`; `todo:411` |
| FR-EDORG-3 | Ordered SEA → LEA → schools | Verified | `kit/http/edorgs.http:48-151`; bootstrap follows file order (`kit/init/bootstrap.sh:255-258`) |
| FR-EDORG-4 | Schools carry consistent grade levels and categories | Verified | K–5 elementary, 6–8 middle, 9–12 high (`kit/bootstrap/baseline-edorgs.json`, checked with `jq` this pass) |
| FR-EDORG-5 | Only minimal-template descriptors; works on fresh minimal | Verified | Bootstrap creates them on a clean minimal start (`todo:411`); `edorgs.http` on minimal (`qa.D` 1.10) |
| FR-EDORG-6 | Re-runnable, no duplicates | Verified | `todo:586`; `qa.D` 1.10 |
| FR-EDORG-7 | Fixed, documented IDs | Verified | `kit/README.md:294-296`; `kit/bootstrap/README.md:12-16` |
| FR-EDORG-8 | IDs don't collide with populated orgs | Verified | `spike:657-666`; CI populated run and `qa.D` Part 3 bootstrap both succeeded. `todo:413` can be ticked |
| FR-EDORG-9 | Verification reads by reference | Verified | `kit/http/edorgs.http:153-164` |
| FR-EDORG-10 | Same variable and token conventions | Verified | `kit/http/edorgs.http:27-46` |
| FR-EDORG-11 | Docs: use the bootstrap credential | Verified | `kit/http/edorgs.http:14-21`; `kit/docs/credentials-and-claim-sets.md:171-173` |
| FR-EDORG-12 | Docs: baseline already exists; file is for more or repair | Verified | `kit/http/edorgs.http:7-10`; `kit/README.md:442-445` |
| FR-EDORG-13 | Docs name the scoped-credential failure and its response | Verified | `kit/http/edorgs.http:17-21`; `kit/docs/credentials-and-claim-sets.md:172-173` |
| FR-EDORG-14 | One source of truth for bootstrap and the file | Verified | `kit/init/check-edorgs-http.sh`, run as smoke step 0 (`kit/init/smoke-test.sh:140`); CI |
| FR-EDORG-15 | Comparative-route sequence | Out of scope | `plan:15-16`; noted in `kit/http/edorgs.http:211-213` |
| FR-EDORG-16 | Show which fields to change to add an org | Verified | Commented templates (`kit/http/edorgs.http:166-209`) |

## 3.14 Documentation

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| FR-DOC-1 | Prerequisites before setup: Docker, resources, ports, certs | Verified | `kit/README.md:45-62`. Disk is stated; RAM and CPU are not (see NFR-PORT-3) |
| FR-DOC-2 | Ordered setup with expected results | Verified | `kit/README.md:88-231` |
| FR-DOC-3 | Written for no Ed-Fi ops experience; terms defined | Verified | `kit/README.md:11-13` and first-use definitions throughout |
| FR-DOC-4 | Default URLs and credentials, labelled local-only | Verified | `kit/README.md:233-261` |
| FR-DOC-5 | Troubleshooting: ports, certs, timeouts, reset, templates, bootstrap | Verified | `kit/docs/troubleshooting.md` (all six sections) |
| FR-DOC-6 | What feedback is wanted and how | Verified | `kit/README.md:485-497` |
| FR-DOC-7 | Verified by following it on a clean host, both templates | Implemented, unverified | `todo:699` unchecked. Needs a fresh reader on a Docker host |
| FR-DOC-8 | Shapes named with path, template, claim set | Verified | `kit/README.md:64-86` |

## 4.1 Usability and Onboarding

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-USE-1 | Credentialed, verified endpoint in under an hour, all shapes and templates | Implemented, unverified | Checkpoint D walk-through passed (`todo:597`), but by the maintainer, not timed, and not by a first-time reader. Closes with FR-DOC-7 |
| NFR-USE-2 | No manual edits to Compose, NGINX, or service config | Verified | `kit/compose.yml:13-15`; every toggle is in `.env` |
| NFR-USE-3 | One commented example `.env` | Verified | `kit/.env.example` |
| NFR-USE-4 | Script errors name cause and next action | Verified | For example `kit/scripts/lib.sh:85-114`, `kit/init/new-credential.sh:164`, `kit/nginx/entrypoint.d/40-kit-features.sh:94-98`; `qa.D` 1.6, 1.8 |

## 4.2 Portability

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-PORT-1 | Docker Desktop on Windows and macOS; Docker Engine on Linux | Known limitation | Windows Docker Desktop (spike, `qa.D`) and Linux Engine (CI `ubuntu-latest`) are verified. No macOS or arm64 run before distribution (D7); the README states both are untested (Prerequisites, Known limitations) |
| NFR-PORT-2 | No single-OS tool; PowerShell and Bash both exist | Verified | Paired scripts; logic lives in containers (`plan:85-96`). PowerShell 7 is required (D8) |
| NFR-PORT-3 | Host resources stated for default and comparative stacks | Known limitation | Disk only. RAM and CPU not measured; no figure published (D5). The README says so under Known limitations. Comparative half is out of scope (D10) |
| NFR-PORT-4 | Host ports configurable | Verified | `HTTP_PORT`, `HTTPS_PORT`, `POSTGRES_PORT`, `BIND_ADDRESS` (`kit/.env.example:25-33`) |
| NFR-PORT-5 | Storage and startup time stated per template | Verified | `kit/README.md` Prerequisites and "The populated template". Spike figures, per D9 (see FR-TMPL-10) |

## 4.3 Security

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-SEC-1 | HTTPS with a local cert; docs separate it from production TLS | Verified | `kit/README.md:265-268` |
| NFR-SEC-2 | Built-in OAuth2; no external IdP | Verified | `AppSettings__IdentityProvider: self-contained` (`kit/compose.core.yml:49`); DMS proxies the token endpoint (`:99`). The ODS/API half is out of scope (D10) |
| NFR-SEC-3 | Secrets from local `.env`; nothing presented as production-suitable | Verified | `${…:?}` in every compose file; `start` generates secrets (`kit/scripts/lib.sh:276-292`) |
| NFR-SEC-4 | Example creds labelled local-only; change if exposed | Verified | `kit/.env.example:9-10`; `kit/README.md:235-237` |
| NFR-SEC-5 | Binds to localhost by default; docs say what changes if exposed | Verified | `BIND_ADDRESS=127.0.0.1` (`kit/.env.example:23-25`); PostgreSQL on `127.0.0.1` (`kit/compose.core.yml:28`); `kit/README.md:235-237` |
| NFR-SEC-6 | No runtime outbound calls; build and first-start calls listed; Swagger UI exception | Verified | PRD clarified 2026-10-06 (D4). Build and first start: image pulls, the tools image from the Ed-Fi Azure Artifacts feed and Ubuntu apt (`kit/tools/Dockerfile:49,104-112`), and the Data Standard zip from GitHub, cached afterwards (`kit/init/template.sh:139-154`). Runtime exception: the browser loads Swagger UI from unpkg.com (`kit/swagger-ui/index.html:15,32,38`). All listed in `kit/README.md` Prerequisites |
| NFR-SEC-7 | Keep supply-chain workflows; official image sources | Verified | `.github/workflows/scorecard.yml`, `on-pullrequest.yml`, `.github/dependabot.yml` retained; DMS and CMS from `edfialliance/`, the rest from official images |
| NFR-SEC-8 | Bootstrap credential generated locally, documented, removable | Verified | Created by CMS per environment, never in the repo (`kit/init/bootstrap.sh:150-177`); removable by reset (verified path) |

## 4.4 Privacy and Data Handling

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-PRIV-1 | Synthetic or de-identified data only | Verified | `kit/README.md:417-419` |
| NFR-PRIV-2 | Logs may contain fragments; review before sharing | Verified | `kit/README.md:419-421,496-497` |
| NFR-PRIV-3 | Reset removes DB; docs say how to remove logs | Verified | `kit/reset.sh:90-93`; `kit/README.md:421-425` |
| NFR-PRIV-4 | Populated is published synthetic data only; docs say so | Verified | `kit/README.md:390-391,419-420` |

## 4.5 Reliability and Reproducibility

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-REL-1 | Health checks; health-based ordering | Verified | Static check this pass: every long-running service has a `healthcheck`; one-shots gate with `service_completed_successfully` (`kit/compose.*.yml`). Only bounded polls, no fixed sleeps (`kit/init/identity.sh:146`, `kit/init/new-credential.sh:417`). `todo:135` can be ticked |
| NFR-REL-2 | Bounded retries and start periods | Verified | Retries 6–18, `start_period` 5–30 s on every health check (`kit/compose.core.yml:29-34,79-84,167-172`, `kit/compose.ingress.yml:43-48,77-82,103-108`) |
| NFR-REL-3 | Same environment everywhere; no `latest`; identical populated data | Verified | Digest pins (FR-PLAT-5); Data Standard content hashes (`kit/.env.example:100-108`). Caveat: tools-image apt packages float by design (`kit/tools/Dockerfile:100-103`) |
| NFR-REL-4 | Volumes survive restarts | Verified | Checkpoint A (`todo:246`); `qa.D` 1.8 |
| NFR-REL-5 | Clean-volume start is the recovery path | Verified | `kit/docs/troubleshooting.md:95-110`; reset then start in CI and Checkpoint C |

## 4.6 Performance

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-PERF-1 | No artificial throughput limits by default | Verified | NGINX limit off (`kit/.env.example:45`); DMS limiter set to 1,000,000 (`kit/compose.core.yml:127-131`) |
| NFR-PERF-2 | Connection pooling configurable | Verified | `CMS_DB_MAX_POOL_SIZE`, `DMS_DB_MAX_POOL_SIZE` (`kit/.env.example:122-124`). The DMS value only applies at first init (`kit/init/datastore.sh:12-15,64-65`); see Known limitations |
| NFR-PERF-3 | Kit claims no performance targets | Verified | None in docs; reporting out of scope |
| NFR-PERF-4 | Docs: single-host Compose isn't performance-representative | Verified | `kit/README.md:393-395` |

## 4.7 Observability

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-OBS-1 | Every service's logs reachable; docs say where | Verified | `kit/README.md:397-411` |
| NFR-OBS-2 | PGAdmin with preconfigured servers | Implemented, unverified | `kit/pgadmin/servers.json`, `PGADMIN_REPLACE_SERVERS_ON_STARTUP` (`kit/compose.ingress.yml:93`); spike login and server check (`spike:681`). `access.json` shows a host pgAdmin session browsing server groups and schemas on 2026-10-04, but `todo:309` is unchecked |
| NFR-OBS-3 | Swagger UI and OpenAPI reachable on documented routes | Verified | `todo:236,307-308` |

## 4.8 Maintainability and SDLC

| Requirement | Summary | Status | Evidence |
| --- | --- | --- | --- |
| NFR-MAINT-1 | Tags, routes, ports, creds, levels, switches from env vars | Verified | `kit/.env.example`; one topology in `kit/compose*.yml` |
| NFR-MAINT-2 | Version bumps are configuration changes | Verified | `f356d16` moved DMS and CMS to `8.1.0-beta1` by editing `.env.example` only |
| NFR-MAINT-3 | Clean-volume start plus smoke test before release | Verified | CI on every PR touching `ed-fi-api-v8/**` |
| NFR-MAINT-4 | Apache-2.0 headers where the file type supports comments | Verified | Static check this pass: every tracked kit file except `.json`, `.png`, and `.md` carries the header. No `.md` in the repo has one, so that's the existing convention. `todo:136` can be ticked |
| NFR-MAINT-5 | Exercise in CI | Verified | `.github/workflows/kit-smoke.yml`; runs listed in `todo:58-62` |

---

## Known limitations

Ready to lift into participant docs. "Documented" says where each one is today. Items marked
*(maintainer)* are for the kit maintainer, not participants.

| # | Limitation | Documented |
| --- | --- | --- |
| 1 | **Swagger UI leaves `pageSize` empty.** DMS advertises a default of 500 but rejects `pageSize` without `pageToken`, so the kit's Swagger UI removes the default. To page with a cursor in Swagger UI, supply both. Upstream: DMS-1588 | `kit/swagger-ui/README.md:23-28` only. Not in `kit/README.md` or `docs/troubleshooting.md` |
| 2 | **Swagger UI needs internet in the browser.** It loads `swagger-ui-dist@5.25.2` from unpkg.com (SRI-pinned). If unpkg.com is blocked, the page doesn't render; the rest of the kit is unaffected | `kit/README.md:371-373` ("Things worth knowing"), `kit/swagger-ui/README.md:81-86`. Not in the README's Known limitations list |
| 3 | **A Profile created while DMS runs isn't usable until DMS restarts** (or up to 30 minutes, `ProfileCacheExpirationSeconds`). Restart with `docker compose restart dms` | `kit/README.md:365-367` and `:470-471` |
| 4 | **A school-scoped SIS credential still reads every school.** `SISVendor`'s school read is `NoFurtherAuthorizationRequired`. Expected platform behavior | `kit/README.md:368-370` |
| 5 | **Windows PowerShell 5.1 is unsupported; PowerShell 7 is required** (D8). The 5.1 code paths were never tested, and `kit/ssl/generate-certificate.ps1` already requires 7 | `kit/README.md` Prerequisites (2026-10-06) |
| 6 | **SELinux enforcing and `userns-remap` (Linux).** Scripts that write `.runtime/` run the tools container as `--user 0:0`. That works with rootful Docker, rootless Docker, and Podman, but not with `userns-remap`. SELinux enforcing (Fedora, RHEL) would block bind mounts without a `:z` label. Untested | `todo:761-764` only. Not in participant docs |
| 7 | *(maintainer)* **`ubuntu-latest` moves to Ubuntu 26 on 2026-10-19.** CI could change underneath the kit (Docker and Compose versions, shellcheck). Date as given in the Checkpoint E brief; not checked against GitHub's announcement in this pass | Not documented |
| 8 | **arm64 is untested.** The locally built tools image has never been built on arm64. This covers most current Macs. No run planned before distribution (D7) | `kit/README.md` Prerequisites and Known limitations (2026-10-06) |
| 9 | **macOS is untested** (NFR-PORT-1). No recorded run on Docker Desktop for Mac, and none planned before distribution (D7) | `kit/README.md` Prerequisites and Known limitations (2026-10-06) |
| 10 | **Claim set changes on a running stack take up to 10 minutes** unless you call the reload endpoint or restart DMS | `kit/README.md:330-337,466-469` |
| 11 | **DMS and CMS logs are not written to `${LOG_DIR}`** (FR-LOG-3). Only NGINX is. Use `docker compose logs dms`/`cms`; Docker log rotation (`DOCKER_LOG_MAX_SIZE`/`DOCKER_LOG_MAX_FILE`) can discard older lines. Accepted for now (D3) | `kit/README.md` "Logs" |
| 12 | **No metrics or reporting tooling** (FR-MET-*) | `kit/README.md:458-460` |
| 13 | **No comparative ODS/API 7.3.2 stack** (FR-COMP-*, v7 halves) | `kit/README.md:455-457` |
| 14 | **The first build and start need network access beyond image pulls** (NFR-SEC-6, as clarified by D4): GitHub for the Data Standard zip on first start, the Ed-Fi Azure Artifacts NuGet feed and Ubuntu apt for the first tools-image build. At runtime, only the browser reaches out, to unpkg.com | `kit/README.md` Prerequisites and Known limitations (2026-10-06) |
| 15 | **`DMS_DB_MAX_POOL_SIZE` and `POSTGRES_PASSWORD` only take effect at first init.** The data store connection string is registered once and encrypted in CMS; changing either afterwards needs `./reset.sh` | `kit/init/datastore.sh:12-15` (code comment) only. Not in `.env.example` or README |
| 16 | **Removing only the bootstrap application through CMS is unverified.** Reset is the verified path | `kit/docs/credentials-and-claim-sets.md:146-165` |
| 17 | **Default SIS and assessment credentials on the populated template are scoped to LEA `255901` only.** They can't write against the baseline hierarchy (`99`/`9900`/`99000x`), the ESC, the PSI, or the community provider without `--edorg-ids` | Partly. The default is in `kit/docs/credentials-and-claim-sets.md:46-50`; the consequence isn't |
| 18 | **A client with no assigned Profile can still opt into any Profile through `Accept`.** ODS/API 7 returns an error instead. Behavior difference, possible upstream issue | `spike:531-534` only |
| 19 | **Self-signed HTTPS is setup friction** | `kit/README.md:472-474` |
| 20 | **DataWarehouse is a kit invention**; results through it aren't reproducible on a stock platform | `kit/README.md:475-477` |
| 21 | **The bootstrap credential is a standing broad-access credential** | `kit/README.md:478-480` |
| 22 | **Single-host timings aren't performance data** | `kit/README.md:393-395` |
| 23 | *(maintainer)* **Tools-image apt packages float** within the digest-pinned base, so two builds on different days can differ in `curl`, `jq`, `psql`, or `openssl` patch levels | `kit/tools/Dockerfile:100-103` |
| 24 | *(maintainer)* **SchemaTools `8.0.1-alpha.0.164` provisions the schema for DMS `8.1.0-beta1`.** It works (CI green), and the pairing is intentional for now (D11) | `kit/.env.example:63-64`, `kit/tools/README.md:55` (comments updated 2026-10-06) |
| 25 | *(maintainer)* **The nightly populated CI job doesn't run on schedule yet.** GitHub runs `schedule` triggers only on the default branch; until this merges to `main`, the populated job runs only on manual dispatch | Not documented |
| 26 | **No RAM or CPU requirement is published** (NFR-PORT-3). Not measured; no figure published (D5) | `kit/README.md` Known limitations (2026-10-06) |

**Stale doc text:** both items found in this pass (the README saying Swagger UI "Try it out" was
unverified, and the leftover "see this document's final report" drafting note) are gone from
`kit/README.md` as of 2026-10-06.

`kit/README.md` line numbers in this file predate the 2026-10-06 README edits and may be off by a
few lines. Check them against the current README.

---

## Unchecked acceptance items

All 38 `- [ ]` items in todo.md Tasks 1–18 and Checkpoints A–C. Run host checks from
`ed-fi-api-v8/` on a running stack unless the check says to reset first. Helper used below:

```bash
# token for the bootstrap credential
T=$(curl -sk -u "$(jq -r .key .runtime/bootstrap-credentials.json):$(jq -r .secret .runtime/bootstrap-credentials.json)" \
  -d grant_type=client_credentials https://localhost/api/oauth/token | jq -r .access_token)
# PilotKitAdmin (CMS) token
A=$(curl -sk https://localhost/config/connect/token --data-urlencode grant_type=client_credentials \
  --data-urlencode client_id=PilotKitAdmin --data-urlencode "client_secret=$(grep ^CMS_ADMIN_CLIENT_SECRET= .env | cut -d= -f2-)" \
  --data-urlencode scope=edfi_admin_api/full_access | jq -r .access_token)
```

### Tick now (closed by this pass or existing evidence)

| Item | Recommendation |
| --- | --- |
| T2 `todo:134` images pinned | Tick. Static check above (FR-PLAT-5) |
| T2 `todo:135` bounded health checks, no sleeps | Tick. Static check above (NFR-REL-1/2) |
| T2 `todo:136` license headers, `.gitignore` | Tick. Static check above (NFR-MAINT-4); `.gitignore:6-11` covers `.env`, `.runtime/*`, `logs/`, `ssl/server.{crt,key}` |
| T4 `todo:239` manual vendor/application, then descriptor GET | Tick. Superseded by Task 13 host QA: `new-credential` does exactly this, then a first GET (`todo:558`) |
| T7 `todo:310` XSD/OpenAPI under `/api/metadata` | Tick. Same check as `todo:236` (checked); Swagger UI loads the specs (`todo:307`) |
| T8 `todo:349` descriptors populated on default start | Tick, and reword. CI minimal `descriptor-list` step passes. "No education organizations exist" is obsolete, since Task 10 creates the baseline |
| T8 `todo:354` gradeLevelDescriptors > 0; marker row | Tick. Smoke `descriptor-list` reads `gradeLevelDescriptors`; `start` prints the template from the marker row (`kit/scripts/lib.sh:592-600`, `qa.D` 1.1) |
| T10 `todo:413` populated, no collision | Tick. CI populated run 37341471550 and `qa.D` Part 3; smoke step 4 writes against `990002`/`990003` on populated |
| Checkpoint C `todo:503` | Tick. The Status section says it passed on the host (`todo:32`); only the box was missed |
| Checkpoint B `todo:321` features that can't be enabled are written down | Tick after the Profiles check below; this file's Known limitations section is the list |

### Host check before distribution

`tasks/host-checks.sh all` runs every row below except pgAdmin and FR-DOC-7 (`list` shows the
check names, which can also be run one at a time). It backs up and restores `.env` around the checks
that change it; `bad-checksum` resets the stack. One correction to the Profiles row: a Profile only
applies to an application it's assigned to (spike-notes, Profiles: assign), so the script creates its
own vendor and application with `profileIds` instead of using the bootstrap credential.

| Item | Command(s) |
| --- | --- |
| T3 `todo:183` invalid secret fails `init-identity`, naming the variable; **also** T4 `todo:233` and FR-LIFE-9 (failure report names the service) | Back up `.env`, set `CMS_ADMIN_CLIENT_SECRET=short` in `.env`, run `./start.sh; echo "exit=$?"`. Expect a non-zero exit, `FAILED: init-identity`, and a log line naming `CMS_ADMIN_CLIENT_SECRET`. Restore `.env` and run `./start.sh` |
| T3 `todo:181` secret rotation | `old=$(grep ^CMS_ADMIN_CLIENT_SECRET= .env \| cut -d= -f2-)`; set a new valid value (32+ chars; lower, upper, digit, special) in `.env`; `./start.sh`; get an `A` token with `$old` (expect a failure) and with the new value (expect 200) |
| T3 `todo:184` secrets never in logs | `for v in POSTGRES_PASSWORD CMS_SERVICE_CLIENT_SECRET CMS_READONLY_CLIENT_SECRET CMS_ADMIN_CLIENT_SECRET CMS_DATABASE_ENCRYPTION_KEY CMS_IDENTITY_ENCRYPTION_KEY; do s=$(grep "^$v=" .env \| cut -d= -f2-); docker compose logs --no-color 2>&1 \| grep -qF -- "$s" && echo "LEAK $v" \|\| echo "ok $v"; done` |
| T3 `todo:187` key and client counts unchanged across two `up` | `q='SELECT (SELECT count(*) FROM dmscs."OpenIddictKey"), (SELECT count(*) FROM dmscs."OpenIddictApplication")'; docker compose exec -T db psql -U postgres -d edfi_datamanagementservice -tAc "$q"; ./start.sh; docker compose exec -T db psql -U postgres -d edfi_datamanagementservice -tAc "$q"` |
| T5 `todo:266` Discovery URLs are `https://localhost/...` (FR-ROUTE-4) | `curl -sk https://localhost/api \| jq .urls` |
| T5 `todo:267` 301 and 503 | Already covered by the CI `http-redirect` step and the 2026-10-04 `service=dms status=503` lines in `access.json`. To confirm in one run: `curl -si http://localhost/api \| head -3; docker compose stop dms; curl -sk https://localhost/api; ./start.sh` |
| T5 `todo:269` missing cert → actionable NGINX error | `mv ssl/server.key ssl/server.key.bak; docker compose up -d --force-recreate nginx; docker compose logs --tail=5 nginx` (expect "TLS file /ssl/server.key not found ... run ./ssl/generate-certificate.sh"); `mv ssl/server.key.bak ssl/server.key; docker compose up -d --force-recreate nginx` |
| T6 `todo:286`, `todo:290` `/data/v3` same body; 404 when off (FR-ROUTE-6) | `diff <(curl -sk -H "Authorization: Bearer $T" https://localhost/data/v3/ed-fi/schools) <(curl -sk -H "Authorization: Bearer $T" https://localhost/api/data/ed-fi/schools) && echo same`. Then set `DATA_V3_REWRITE_ENABLED=false`, `docker compose up -d nginx`, `curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/data/v3/ed-fi/schools` (expect 404), `./smoke-test.sh` (expect `data-v3-rewrite` PASS "disabled"). Restore and run `docker compose up -d nginx` |
| T6 `todo:287`, `todo:290` rate limiting (FR-ROUTE-8) | Set `RATE_LIMIT_ENABLED=true`, `RATE_LIMIT_RATE=1r/s`, `RATE_LIMIT_BURST=0`; `docker compose up -d nginx`; `for i in $(seq 20); do curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/api; done \| sort \| uniq -c` (expect some 429). Restore. The default case already holds: no 429 in `access.json` |
| T7 `todo:309`, `todo:313` pgAdmin shows the server (NFR-OBS-2) | Browser: `https://localhost/pgadmin/`, log in with `PGADMIN_DEFAULT_EMAIL`/`PGADMIN_DEFAULT_PASSWORD` from `.env`, expand "Ed-Fi Pilot Kit", connect with `POSTGRES_PASSWORD`. `access.json` suggests this already happened on 2026-10-04; just confirm and tick |
| Checkpoint B `todo:320` 3.4 spot check; Profiles (FR-FEAT-5) | Change queries, ETag, and both paging modes are in CI smoke. For Profiles: `curl -sk -X POST https://localhost/config/v3/profiles -H "Authorization: Bearer $A" -H 'Content-Type: application/json' -d '{"name":"Kit-School-Names","definition":"<Profile name=\"Kit-School-Names\"><Resource name=\"School\"><ReadContentType memberSelection=\"IncludeOnly\"><Property name=\"nameOfInstitution\"/></ReadContentType></Resource></Profile>"}'`; `docker compose restart dms`; refresh `T`; `curl -sk -H "Authorization: Bearer $T" -H 'Accept: application/vnd.ed-fi.school.kit-school-names.readable+json' 'https://localhost/api/data/ed-fi/schools?limit=1'` (expect only `nameOfInstitution`, `schoolId`, and metadata fields) |
| T8 `todo:351` partial failure leaves no marker; **also** T9 `todo:380` corrupted archive fails clearly (FR-TMPL-7) | `./reset.sh --force`; set `DATA_STANDARD_SAMPLES_SHA256` to 64 zeros in `.env`; `./start.sh --template populated; echo "exit=$?"` (expect non-zero, `FAILED: init-template`, a `[fetch-source]` line naming `DATA_STANDARD_SAMPLES_SHA256`); `docker compose exec -T db psql -U postgres -d edfi_datamanagementservice -tAc 'SELECT count(*) FROM kit.initialization'` (expect 0); restore the value; `./start.sh` (expect it to load and exit 0) |
| T9 `todo:385` student count | `./new-credential.sh --shape warehouse --name tc-wh`; `W=$(curl -sk -u "$(jq -r .key .runtime/credentials/tc-wh.json):$(jq -r .secret .runtime/credentials/tc-wh.json)" -d grant_type=client_credentials https://localhost/api/oauth/token \| jq -r .access_token)`; `curl -sk -D- -o /dev/null -H "Authorization: Bearer $W" 'https://localhost/api/data/ed-fi/students?limit=1&totalCount=true' \| grep -i total-count` (expect 960) |
| T11 `todo:443` DataWarehouse listed; metadata Read and ReadChanges only | `curl -sk -H "Authorization: Bearer $A" 'https://localhost/config/v3/claimSets?limit=500' \| jq -r '.[].claimSetName' \| grep DataWarehouse`; `curl -sk -H "Authorization: Bearer $A" 'https://localhost/config/v3/authorizationMetadata?claimSetName=DataWarehouse' \| jq '[..\|.actions?//empty\|.[].name]\|unique'` |
| T11 `todo:445` warehouse reads everything; writes 403 (FR-CLAIM-6) | With the `tc-wh` token on populated: `GET .../students/deletes` → 200; `POST .../students` with `{}` → 403; `DELETE` on any student `id` → 403. The full 349-endpoint sweep is optional; the spike did it on the older image |
| FR-CLAIM-10 (no todo item) unknown claim set rejected; FR-CRED-10 override | `./new-credential.sh --shape sis --name tc-bad --claim-set NoSuchSet; echo "exit=$?"` (expect non-zero and a list of valid sets). `./new-credential.sh --shape sis --name tc-school --edorg-ids 990002` (expect exit 0) |
| T18 `todo:491`, `todo:495` claim set change on a running stack is reloaded | `mkdir -p /tmp/kit-cs && jq '.claimSetName="KitReloadTest"' bootstrap/claimsets/DataWarehouse.json > /tmp/kit-cs/KitReloadTest.json`; `docker compose run --rm --no-deps -e CLAIMSETS_DIR=/kit-cs -v /tmp/kit-cs:/kit-cs:ro init-claimsets` (expect "claim set 'KitReloadTest' reloaded; usable immediately"); `./new-credential.sh --shape warehouse --name tc-reload --claim-set KitReloadTest` (its built-in first request must be 200, not 500). Leaves a throwaway claim set; reset afterwards. Note that `./bootstrap.sh` never imports claim sets, so the item's "bootstrap" wording means `init-claimsets` |
| T16 `todo:699` FR-DOC-7, and NFR-USE-1 | A first-time reader follows `kit/README.md` on a clean host, once per template, timing it from clone to first credentialed request. No macOS run is required (D7) |

### Accept as limitation, or fold into the human review

| Item | Recommendation |
| --- | --- |
| Checkpoint A `todo:247` review with human | Fold into Checkpoint E's human review (`todo:772`) |
| T4 `todo:232` TPDM-filled volume restaged as core only | Accept on code evidence: `init-api-schema` runs before DMS, checks the hash and manifest, and restages anything else; DMS mounts with `nocopy` (`kit/compose.core.yml:147-152`). Optional host check: `./reset.sh --force; docker volume create edfi-pilot_api-schema; docker run --rm --entrypoint true -v edfi-pilot_api-schema:/app/ApiSchema "$(grep ^DMS_IMAGE= .env \| cut -d= -f2-)"; ./start.sh; docker compose logs init-api-schema \| tail; curl -sk https://localhost/api \| jq .dataModels` (expect Ed-Fi only). Compose will warn that it didn't create the volume |
| T11 `todo:449` standard claim sets byte-identical | Accept on code evidence: `kit/init/claimsets.sh:224-230` refuses any system-reserved name, and the only writes are `/v3/claimSets/import` of the files in `kit/bootstrap/claimsets/`. A real before/after export diff needs CMS up before `init-claimsets` ever runs, which takes more steps than the risk warrants |
| T9 `todo:381` load time and volume size (FR-TMPL-10, NFR-PORT-5) | Accept by D9: the README publishes the spike's figures. Remeasuring is optional: after a populated start, `docker system df -v \| grep -E 'db-data\|api-schema'` and the wall time of `./start.sh` |
| T11 `todo:452`, T18 `todo:496` scripted checks in the smoke test | Accept for this round. The host QA, `http/warehouse-claimset.http`, and `http/claimset-test.http` cover them, and FR-TEST-4 doesn't require them. A warehouse step in `smoke-test` would be a cheap follow-up |

---

## Decisions (resolved 2026-10-06)

Answered by the maintainer on 2026-10-06 and applied to the rows above.

1. **D1:** FR-TMPL-9 wins (assessment → populated). FR-TMPL-6 is removed from the PRD; the other
   FR-TMPL IDs keep their numbers.
2. **D2:** The second `FR-FEAT-9` is renumbered `FR-FEAT-10`, and FR-CLAIM-7 now cites FR-FEAT-9.
3. **D3:** FR-LOG-3: DMS and CMS file logs are accepted as a known limitation for now. No PRD change.
4. **D4:** NFR-SEC-6 now separates build and first-start calls (image pulls, the tools-image build
   from Azure Artifacts and apt, the Data Standard download from GitHub) from runtime, with the
   browser's unpkg.com load as a documented exception.
5. **D5:** No RAM or CPU figure will be published for now. NFR-PORT-3 is a known limitation; the
   PRD requirement is unchanged.
6. **D6:** The `new-credential --claim-set` override stays unrestricted. No code change.
7. **D7:** No macOS or arm64 run before distribution; the kit states both are untested.
8. **D8:** Windows PowerShell 5.1 is dropped; PowerShell 7 is required.
9. **D9:** The README publishes the spike's populated load time.
10. **D10:** Confirmed: FR-TMPL-3, the comparative half of NFR-PORT-3, and the ODS/API half of
    NFR-SEC-2 are out of scope with the v7 halves (`plan:14-21`). ODS/API v7 support comes later.
11. **D11:** SchemaTools `8.0.1-alpha.0.164` with DMS and CMS `8.1.0-beta1` is fine for now; the
    stale comments are fixed.
12. **D12:** `http/warehouse-claimset.http` is maintainer-owned; the maintainer will fix the
    hard-coded `vendorId` and `educationOrganizationIds` personally.

---

AI assistance: this trace was drafted by Claude (Claude Code) from the repository's files, with no
access to a running stack. Statuses rest on the cited evidence and on static reading of the code;
"Implemented, unverified" rows need the listed host checks. Review it before relying on it, and
note AI assistance if any of it is used in participant-facing or board material.
