# Ed-Fi API v8 Pilot Testing Kit

A self-contained [Docker Compose](https://docs.docker.com/compose/) environment for testing a
client integration -- a system that reads from or writes to an Ed-Fi API -- against
[Ed-Fi API v8](https://docs.ed-fi.org/reference/ed-fi-api/8/), also called the **DMS** (Data
Management Service). It brings up DMS, the **CMS** (Configuration Management Service, which manages
API credentials), PostgreSQL, an HTTPS ingress, Swagger UI, and PGAdmin, pre-loaded with one of two
starting data sets and a baseline set of education organizations, so you can get a credentialed,
authenticated API call working without first learning Ed-Fi platform operations.

This document assumes no prior Ed-Fi platform operations experience. Ed-Fi-specific terms are
defined the first time they're used; the full set of definitions is in the
[PRD glossary](../docs/client-integration-pilot-PRD.md#8-glossary).

If you want the rationale behind how the kit is built rather than how to use it, see
[`../tasks/plan.md`](../tasks/plan.md).

## Contents

- [Ed-Fi API v8 Pilot Testing Kit](#ed-fi-api-v8-pilot-testing-kit)
  - [Contents](#contents)
  - [Prerequisites](#prerequisites)
  - [Which instructions apply to you](#which-instructions-apply-to-you)
  - [Setup](#setup)
    - [1. Clone and change into the kit directory](#1-clone-and-change-into-the-kit-directory)
    - [2. (Optional) Review configuration before the first start](#2-optional-review-configuration-before-the-first-start)
    - [3. Start the kit](#3-start-the-kit)
    - [4. Create an integration credential](#4-create-an-integration-credential)
    - [5. Run the smoke test](#5-run-the-smoke-test)
    - [6. Make your first authenticated request](#6-make-your-first-authenticated-request)
  - [URLs, routes, and default credentials](#urls-routes-and-default-credentials)
  - [Trusting the certificate from your own client code](#trusting-the-certificate-from-your-own-client-code)
  - [The bootstrap (admin) credential](#the-bootstrap-admin-credential)
  - [The Data Warehouse claim set](#the-data-warehouse-claim-set)
  - [Applying a claim set change immediately](#applying-a-claim-set-change-immediately)
  - [Things worth knowing before you dig in](#things-worth-knowing-before-you-dig-in)
  - [The populated template](#the-populated-template)
  - [Logs](#logs)
  - [Privacy](#privacy)
  - [Stopping, resetting, and switching templates](#stopping-resetting-and-switching-templates)
  - [Troubleshooting](#troubleshooting)
  - [Known limitations](#known-limitations)
  - [Feedback](#feedback)

## Prerequisites

- **Docker and Compose.** Docker Desktop (Windows or macOS) or Docker Engine (Linux), with
  Compose 2.20 or later (check with `docker compose version`). This kit was verified with Docker
  Desktop 29.7.2.
- **Free host ports**, all configurable in `.env` if they're already taken on your machine:
  - `80` (`HTTP_PORT`) -- redirects to HTTPS
  - `443` (`HTTPS_PORT`) -- the kit's HTTPS ingress
  - `5435` (`POSTGRES_PORT`) -- PostgreSQL, bound to `127.0.0.1` only, for host database tools
- **Disk space.** A few GB for the pulled and locally built images (NGINX, PostgreSQL, PGAdmin,
  CMS, DMS, and a `tools` image built from a .NET SDK base image on first start), plus the database
  volume itself: roughly 130 MB total for the **minimal** template, or roughly 700 MB total for the
  **populated** template (measured during kit verification; see
  [The populated template](#the-populated-template) for the full breakdown). No separate minimum RAM
  figure is documented here -- see this document's final report for that gap.
- **A TLS certificate.** `./start.sh` (or `.ps1`) generates a local, self-signed one for you under
  `ssl/` automatically if it doesn't already exist. You can also run `ssl/generate-certificate.sh`
  (or `.ps1`) yourself first if you'd rather do it as a separate step.

## Which instructions apply to you

The kit supports three integration shapes. Pick the row that matches what you're building before
you start anything else:

| You are building... | Starting command | Template | Claim set |
| --- | --- | --- | --- |
| A **SIS** (Student Information System) integration: writing enrollment, demographic, staff, schedule, and calendar data | `./new-credential.sh --shape sis --name <your-name>` | minimal (the default) | `SISVendor` |
| An **assessment provider** integration: writing assessment metadata and student results that reference existing students and education organizations | `./new-credential.sh --shape assessment --name <your-name>` | populated | `AssessmentVendor` |
| A **downstream data warehouse or analytics** integration: reading data out through full extracts and change queries | `./new-credential.sh --shape warehouse --name <your-name>` | populated | `DataWarehouse` -- a kit addition, not a standard Ed-Fi claim set; see [below](#the-data-warehouse-claim-set) |

A **claim set** is the named authorization configuration that determines which resources and
actions a credential may use. `new-credential` picks the right one for you from `--shape`; you
don't need to look it up yourself.

The warehouse/analytics case needs data to already exist before there's anything to extract, so it
requires the populated template. The assessment case needs existing students and education
organizations to reference, so it also needs the populated template; a SIS integration writes its
own data, so the minimal (empty) template is the better starting point and the default.

See [`docs/credentials-and-claim-sets.md`](docs/credentials-and-claim-sets.md) for the full
`new-credential` flag reference, the per-shape education organization scoping defaults, and more
detail on every claim set.

## Setup

Each step below says what to run and what to expect before moving to the next one. Bash and
PowerShell commands behave identically.

### 1. Clone and change into the kit directory

```bash
git clone https://github.com/Ed-Fi-Exchange-OSS/DMS-pilot-testing-kit.git
cd DMS-pilot-testing-kit/ed-fi-api-v8
```

### 2. (Optional) Review configuration before the first start

Every setting lives in one file, `.env.example`, with comments. **You can skip this step**:
`./start.sh`/`.ps1` creates `.env` for you in the next step, with freshly generated local secrets.
Only do this yourself first if you need to change something before the first start -- for example
`HTTP_PORT`, `HTTPS_PORT`, `POSTGRES_PORT`, or `DATABASE_TEMPLATE`:

```bash
cp .env.example .env
```

If you copy it yourself, the secret values stay at `.env.example`'s published placeholders (for
example `POSTGRES_PASSWORD=LocalDevOnly-Postgres-1!`) until you change them, because an existing
`.env` is never modified automatically. Letting `start` create `.env` for you avoids that: it
replaces `POSTGRES_PASSWORD`, `CMS_SERVICE_CLIENT_SECRET`, `CMS_READONLY_CLIENT_SECRET`,
`CMS_ADMIN_CLIENT_SECRET`, `CMS_DATABASE_ENCRYPTION_KEY`, `CMS_IDENTITY_ENCRYPTION_KEY`, and
`PGADMIN_DEFAULT_PASSWORD` with values generated only for your own environment.

### 3. Start the kit

```shell
# Bash
./start.sh

# PowerShell
.\start.ps1
```

This checks that Docker is running and Compose 2.20 or later is available, creates `.env` if it
doesn't exist (with generated secrets, as above), generates the TLS certificate if missing, creates
`.runtime/` and the log directory, and runs `docker compose up -d --build --wait`. **The first run
can take a few minutes**: pulling images, building the `tools` image, provisioning the database schema, and
loading the starting template all happen before the command returns. On the `populated` template,
budget an extra ~5 minutes for the sample data load (see
[The populated template](#the-populated-template)).

On success, you'll see something close to this:

```text
Ed-Fi API v8 pilot kit is up.

  API / Discovery:  https://localhost/api
  Token endpoint:   https://localhost/api/oauth/token
  CMS config:       https://localhost/config
  Swagger UI:       https://localhost/swagger
  PGAdmin:          https://localhost/pgadmin

Template in use: minimal

Bootstrap (admin) credentials: .../ed-fi-api-v8/.runtime/bootstrap-credentials.json
This is an administrative credential for local testing only -- it is not representative of
a production integration client.

Next steps:
  - Create a scoped credential: ./new-credential.sh --shape sis --name <your-name>
  - Run the smoke test:         ./smoke-test.sh
```

If it fails, `start` names the failing service(s), prints their last 20 log lines, and shows the
exact `docker compose logs <service>` command to see more -- see
[Troubleshooting](#troubleshooting). Running `start` again against an already-running stack exits 0
and changes nothing.

To start on the populated template instead of the default minimal one:

```shell
# Bash
./start.sh --template populated

# PowerShell
.\start.ps1 -Template populated
```

This only takes effect on a database that hasn't been initialized yet. Changing `DATABASE_TEMPLATE`
on an already-initialized database requires `./reset.sh --start` (see
[Stopping, resetting, and switching templates](#stopping-resetting-and-switching-templates)).

### 4. Create an integration credential

Using the shape table [above](#which-instructions-apply-to-you), for example:

```shell
# Bash
./new-credential.sh --shape sis --name my-sis-client

# PowerShell
.\new-credential.ps1 -Shape sis -Name my-sis-client
```

Expected output (printed once -- the secret can't be recovered later, so save it now):

```text
---------------------------------------------------------------
Credential "my-sis-client" created (shape=sis, claimSet=SISVendor)
Key:       <generated>
Secret:    <generated>
Token URL: https://localhost/api/oauth/token
Saved to:  ed-fi-api-v8/.runtime/credentials/my-sis-client.json
WARNING: this secret cannot be recovered later -- store it now.
---------------------------------------------------------------
```

The script also makes one authorized request with the new credential before printing this, so a
successful run means the credential already works end to end with no extra configuration.

### 5. Run the smoke test

```shell
# Bash
./smoke-test.sh

# PowerShell
.\smoke-test.ps1
```

Exercises a token request, Discovery, a descriptor read, a write and read-back, limit/offset and
cursor paging, a change-query extract, an ETag update plus a deliberately stale ETag, a
deliberately invalid request, and -- only on the populated template -- an assessment-style
reference write. Prints one PASS/FAIL/SKIP line per step and a summary, and exits non-zero if
anything failed.

### 6. Make your first authenticated request

Use the `Token URL` and your new credential's key/secret from step 4, or open
[`http/smoke.http`](http/smoke.http) in VS Code with the
[REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) extension and
paste your credential into its `@key`/`@secret` variables. `http/smoke.http` is the same sequence
`smoke-test` runs, one request at a time, with the actual responses visible.

## URLs, routes, and default credentials

**Everything below is a local-development-only value** (NFR-SEC-4). NGINX binds only to
`BIND_ADDRESS` (default `127.0.0.1`); changing it to `0.0.0.0` exposes the kit, and every credential
below, to your network.

| Route | What it is | Notes |
| --- | --- | --- |
| `https://localhost/api` | DMS (Ed-Fi API v8) Discovery | path from `DMS_PATH_BASE` (default `api`) |
| `https://localhost/api/oauth/token` | OAuth2 token endpoint | client-credentials grant only |
| `https://localhost/config` | CMS | path from `CMS_PATH_BASE` (default `config`); manages vendors, applications, and credentials |
| `https://localhost/swagger/` | Swagger UI | see [below](#things-worth-knowing-before-you-dig-in) -- needs internet access in your browser |
| `https://localhost/pgadmin/` | PGAdmin | see [below](#things-worth-knowing-before-you-dig-in) -- prompts for the database password |
| `https://localhost/data/v3/...` | rewritten to `/api/data/...` | toggle: `DATA_V3_REWRITE_ENABLED` (default `true`); see the caveat below |
| `127.0.0.1:5435` | PostgreSQL | `POSTGRES_PORT`; for host database tools such as `psql` |

**The `/data/v3` rewrite is a pilot compatibility affordance, not a supported Ed-Fi API v8 path.**
It exists so a client that hard-codes the legacy `/data/v3` path segment can participate without a
code change first. Set `DATA_V3_REWRITE_ENABLED=false` in `.env` to test against native v8 paths
only (it then 404s instead of rewriting). If your own client relies on it, the pilot program
specifically wants to know.

**Default credentials.** On first run, `start` creates `.env` from `.env.example` and immediately
replaces the published placeholder values for `POSTGRES_PASSWORD`, `CMS_SERVICE_CLIENT_SECRET`,
`CMS_READONLY_CLIENT_SECRET`, `CMS_ADMIN_CLIENT_SECRET`, `CMS_DATABASE_ENCRYPTION_KEY`,
`CMS_IDENTITY_ENCRYPTION_KEY`, and `PGADMIN_DEFAULT_PASSWORD` with values generated only for your
environment -- nothing in the repository is a value you'd actually authenticate with. Open your own
`.env` to read one of them (for example, to log into PGAdmin below). `PGADMIN_DEFAULT_EMAIL` stays
at its example value, `admin@example.com`, unless you change it.

## Trusting the certificate from your own client code

The kit's HTTPS certificate (`ssl/server.crt`) is self-signed, for `localhost`/`nginx`/`127.0.0.1`
only, and valid for local development only (NFR-SEC-1) -- this is not how production Ed-Fi API v8
deployments terminate TLS. Your client needs to either trust it or skip verification in a way you
would never do for a real endpoint:

- **curl:** `curl --cacert ssl/server.crt https://localhost/api`
- **Python (`requests`):** `requests.get(url, verify="ssl/server.crt")`
- **Node.js:** set the environment variable `NODE_EXTRA_CA_CERTS=ssl/server.crt` before your process
  starts.
- **.NET:** `HttpClient` validates against the OS certificate trust store by default, so trusting
  `server.crt` at the OS level covers it too:
  - Windows: `certutil -addstore -user Root ssl\server.crt`
  - macOS: `security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db ssl/server.crt`
  - Linux: `sudo cp ssl/server.crt /usr/local/share/ca-certificates/edfi-pilot-kit.crt && sudo update-ca-certificates`

  For a quick, dev-only shortcut instead of trusting the certificate at the OS level, a custom
  `HttpClientHandler.ServerCertificateCustomValidationCallback` that returns `true` skips
  verification entirely -- only ever appropriate for this local kit, never for code that might run
  against a real endpoint.

If you use a hostname other than `localhost` to reach the kit, regenerate the certificate to include
it (the script's SANs are `localhost`, `nginx`, and `127.0.0.1`; see `ssl/generate-certificate.sh
--help`).

## The bootstrap (admin) credential

Startup creates one broad-access **bootstrap credential** -- a "Pilot Kit Bootstrap (ADMIN)" vendor
and application using the standard `EdFiSandbox` claim set -- and uses it to create a baseline
**education organization hierarchy** (the parent-child chain from state agency to district to
school; Ed-Fi calls this abstraction an **education organization**): one State Education Agency
(SEA, id `99`), one Local Education Agency (LEA, id `9900`), and three schools (`990001`, `990002`,
`990003`). A participant credential has to be scoped to an education organization to do anything
useful, and a freshly initialized minimal-template database has none yet -- the bootstrap credential
exists to break that chicken-and-egg problem, not to be used for integration testing.

Its key and secret are written to `.runtime/bootstrap-credentials.json`, the only place the secret
is recoverable after creation. It is **not representative of a production integration client**: it
can create, read, update, and delete data anywhere in the hierarchy it's scoped to. It is also
narrower than "everything" -- `EdFiSandbox` reads people (students, staff, contacts) through the
`RelationshipsWithEdOrgsAndPeople` authorization strategy, so this credential cannot read arbitrary
students outside organizations it's related to.

Use a credential from [`new-credential`](#which-instructions-apply-to-you) for integration testing
instead. See [`docs/credentials-and-claim-sets.md`](docs/credentials-and-claim-sets.md) for the
credential file's exact fields and how to rotate or remove this credential once you no longer want
it present.

## The Data Warehouse claim set

No standard Ed-Fi claim set grants broad read access, so the kit adds one: **`DataWarehouse`**,
which grants `Read` and `ReadChanges` (the action that gates `/deletes`, `/keyChanges`, and
change-query extracts) on every resource and descriptor domain, with no education organization
scoping and no Create/Update/Delete. It's defined in version control at
[`bootstrap/claimsets/DataWarehouse.json`](bootstrap/claimsets/DataWarehouse.json), reviewable like
any other file in this repository.

Use file [warehouse-claimset.http](./http/warehouse-claimset.http) to create and test a
set of credentials using the `DataWarehouse` claimset.

**This is a kit invention, not a standard Ed-Fi Alliance claim set.** The absence of a read-all
claim set in the platform is itself one of the things this pilot can help confirm one way or the
other -- if you have feedback on whether this claim set's shape matches what a real downstream
integration needs, that is exactly the kind of feedback the pilot wants (see
[Feedback](#feedback)).

## Applying a claim set change immediately

Ed-Fi API v8 caches claim set information, so a claim set imported or changed while DMS is already
running isn't picked up right away -- requests can return `HTTP 500` for up to 10 minutes until the
cache refreshes. The kit avoids this for its own `DataWarehouse` claim set by importing it before
DMS starts, but if **you** add or change a claim set on an already-running stack, force an immediate
reload:

```http
POST https://localhost/api/management/reload-claimsets
Authorization: Bearer <token with the dms-management-operator role>
```

Only the kit's `PilotKitAdmin` CMS client carries the required role
(`DMS_CLAIMSET_RELOAD_ROLE`, default `dms-management-operator`) -- a participant integration
credential gets `403`, and an unauthenticated request gets `401`. Get a token for it the same way
[`http/claimset-test.http`](http/claimset-test.http) does:

```http
POST https://localhost/config/connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials&client_id=PilotKitAdmin&client_secret=<CMS_ADMIN_CLIENT_SECRET from .env>&scope=edfi_admin_api/full_access
```

`GET https://localhost/api/management/view-claimsets` (same bearer token) lists what DMS currently
has cached, useful for confirming a reload took effect. Set `DMS_CLAIMSET_RELOAD_ENABLED=false` in
`.env` to turn both endpoints off entirely (`404`); the rest of the stack is unaffected.

## Things worth knowing before you dig in

A few behaviors you'll likely run into, each worth one sentence:

- **PGAdmin prompts for the database password on connect.** The preconfigured server definition
  deliberately stores no password; enter `POSTGRES_PASSWORD` from your `.env` when PGAdmin asks.
- **A Profile created while DMS is already running isn't usable until DMS restarts** (or up to 30
  minutes pass, DMS's Profile cache window) -- the kit ships no Profiles itself, but if you add one
  through CMS, restart DMS (`docker compose restart dms`) before relying on it.
- **A school-scoped SIS credential can still read every school in the hierarchy**, not just the one
  it's scoped to -- `SISVendor`'s school read uses an authorization strategy that doesn't further
  restrict by education organization. This is expected Ed-Fi platform behavior, not a kit defect.
- **Swagger UI needs internet access in your browser.** `/swagger/` loads `swagger-ui-dist` from
  `unpkg.com` at browse time; if your network blocks it, the page won't render even though the rest
  of the kit is unaffected.

## The populated template

The **populated template** (DS 5.2's published synthetic sample data set, on top of the minimal
template's descriptors) exists for read-oriented and reference-resolving testing, which needs data
to already be there. It adds:

- the sample district **Local Education Agency 255901 ("Grand Bend ISD")**, an education service
  center (`255950`), a post-secondary institution (`6000203`), and a community provider
  (`19255901`) -- none of these collide with the kit's own baseline hierarchy (`99`/`9900`/`990001`-`990003`)
- 3 sample schools under that LEA, for 6 schools total once the baseline hierarchy is also created
- **960 students**, 1,873 contacts, 68 staff, 40,320 grades, 13,667 course transcripts, 13,440
  student section associations, and 71 student health records

**Cost relative to the minimal template** (FR-TMPL-10, NFR-PORT-5): about +5 minutes on the first
start, about +140 MB of database size (about 194 MB total), and about +570 MB of volume size on
disk (about 700 MB total for `db-data`). It contains **only the published Ed-Fi synthetic sample
data** -- no real student records of any kind.

These are single-host measurements, not a performance benchmark (NFR-PERF-4): a single-machine
Compose environment is not a performance-representative deployment, so don't read throughput or
timing claims into these numbers beyond "how long will my own first start take."

## Logs

- **NGINX** writes one JSON object per request to `${LOG_DIR:-./logs}/nginx/access.json` (time,
  request and correlation IDs, client address, method, the raw and rewritten URI, status, sizes,
  timing, the upstream service/address/status/time, and whether the `/data/v3` rewrite applied), and
  warnings/errors to `error.log` in the same directory. Both survive `docker compose down`, since
  they're on the host filesystem, not only in the container.
- **DMS and CMS are not file-logged to that directory.** Read their logs with
  `docker compose logs dms` / `docker compose logs cms` (or `docker logs`). Set `DMS_LOG_LEVEL` /
  `CMS_LOG_LEVEL` in `.env` (`Debug`, `Information`, `Warning`, `Error`) to change verbosity; DMS
  defaults to `Warning` because at `Information` it writes enough per request that Docker's own log
  rotation can discard an error window within minutes during a populated-template load.
- **A correlation ID ties a request together across services.** Send a `correlationid` request
  header yourself, or NGINX generates one; it appears in both the NGINX access log and the DMS
  log lines for that request.
- `MASK_REQUEST_BODY_IN_LOGS=true` (the default) keeps request bodies out of `Debug`-level logs --
  leave it on unless you specifically need bodies and understand they may contain submitted data.

## Privacy

This kit's data stores -- the databases DMS and CMS read from and write to -- are intended for
**synthetic or de-identified data only**. Do not submit real student records into this environment.
The populated template's sample data is itself entirely synthetic. Logs and anything you extract
from the API may contain payload fragments and identifiers from whatever you did submit; review
them before sharing outside your organization. `./reset.sh` removes the persisted database
contents; it does not remove `${LOG_DIR:-./logs}/` or anything under `.runtime/credentials/` on its
own initiative beyond what's documented in
[Stopping, resetting, and switching templates](#stopping-resetting-and-switching-templates) --
delete those directories yourself if you want logs and saved credentials gone too.

## Stopping, resetting, and switching templates

- **Stop, keep data:** `./stop.sh` / `.ps1` (`docker compose stop`). Persisted data -- the
  database, the ApiSchema volume, and PGAdmin's data -- is kept. Start it again with `./start.sh`.
- **Destructive reset:** `./reset.sh` / `.ps1` (`docker compose down -v --remove-orphans`) removes
  every persisted volume and every file under `.runtime/` except `.gitkeep` -- the bootstrap
  credential and any credentials you provisioned stop working. `.env` and the TLS certificate are
  kept. Without `--force`/`-Force`, it prompts for confirmation and shows exactly what will be
  removed first; answering anything but `yes`, or running it with no terminal attached, changes
  nothing. Add `--start`/`-Start` to bring the kit back up immediately afterward.
- **Switching `DATABASE_TEMPLATE`:** only takes effect on a database that hasn't been initialized
  yet. Changing it in `.env` (or via `./start.sh --template populated`) against an already-initialized
  database does not reload anything -- the template loader detects the mismatch and leaves the
  database as-is, logging a warning that a reset is required. Run `./reset.sh --start` to actually
  switch.
- **Repair bootstrapping without a full reset:** `./bootstrap.sh` / `.ps1` reruns the bootstrap
  credential and baseline hierarchy creation against an already-running stack (`docker compose run
  --rm init-bootstrap`); useful if `bootstrap-credentials.json` was lost or a baseline record was
  deleted by hand. Requires the stack to already be running.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for port conflicts, certificate trust
failures, startup timeouts and failures, volume reset, switching templates, and bootstrapping
failures, each with the exact command or message to look for.

## Known limitations

- **The comparative Ed-Fi ODS/API 7.3.2 environment described in the PRD is not part of this kit.**
  The `odsapi` Compose profile, ODS Admin API, and every requirement tagged `FR-COMP` are explicitly
  out of scope for this build, as are the v7 halves of a few other requirements.
- **There is no scripted metrics/reporting tooling.** Log parsing and run reports (PRD section
  3.11, `FR-MET-*`) are explicitly out of scope for this build; error counts, record counts, and
  timing are things you'll need to assemble yourself from the logs described above.
- **arm64 is untested.** Every build and measurement in this kit's verification was done on an
  amd64 host; the locally built `tools` image in particular has not been built or run on arm64.
- **Swagger UI's "Try it out" has not been verified in-browser.** The equivalent same-origin
  `curl` calls (token, then an authenticated `GET`) pass; the interactive browser flow with a
  pasted token has not been separately checked.
- **A claim set change on an already-running stack can take up to 10 minutes to take effect** if you
  don't call the reload endpoint described [above](#applying-a-claim-set-change-immediately) -- the
  kit's own `DataWarehouse` claim set avoids this by importing before DMS starts, but a claim set
  you add yourself will need either the reload call or a DMS restart.
- **A Profile created while DMS is running isn't usable for up to 30 minutes** without a DMS
  restart (see [above](#things-worth-knowing-before-you-dig-in)).
- **Self-signed HTTPS is friction against a fast setup.** Certificate trust is the most likely place
  to stall; see [Trusting the certificate](#trusting-the-certificate-from-your-own-client-code) and
  [Troubleshooting](#troubleshooting).
- **The `DataWarehouse` claim set is a kit invention**, so authorization results observed through it
  are not reproducible against a stock Ed-Fi API v8 platform; see
  [above](#the-data-warehouse-claim-set).
- **The bootstrap credential is a standing broad-access credential in your environment** until you
  remove it (see [`docs/credentials-and-claim-sets.md`](docs/credentials-and-claim-sets.md));
  authorization behavior observed through it is not representative of a production client.
- Microsoft SQL Server, Ed-Fi Admin App, Keycloak or any external identity provider,
  multi-tenancy, custom education organization hierarchies, Data Standard versions other than 5.2,
  Ed-Fi extensions/TPDM, and production deployment guidance are all out of scope for this kit.

## Feedback

GitHub Issues are enabled for everyone on this repository -- post problems or requests there rather
than through an Ed-Fi Community case (see the [root README](../README.md)). Feedback the pilot
specifically wants:

- Whether the `DataWarehouse` claim set's shape (read-everything, no education organization
  scoping) matches what a real downstream integration needs.
- Whether your client relied on the `/data/v3` compatibility rewrite rather than native v8 paths.
- Anything else that made setup slower or more confusing than this document implies it should be.

Review logs, extracted data, and anything else you plan to share for identifiers or payload
fragments first (see [Privacy](#privacy)).
