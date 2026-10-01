# Credentials and claim sets

This is the detailed companion to the [main README](../README.md)'s
[integration shapes table](../README.md#which-instructions-apply-to-you): the full
`new-credential` flag reference, exactly how education organization scoping defaults are chosen,
the bootstrap credential's file format and how to rotate or remove it, and more detail on every
claim set the kit uses.

A **claim set** is the named authorization configuration that determines which resources and
actions a credential may use (see the
[PRD glossary](../../docs/client-integration-pilot-PRD.md#8-glossary)). An **education
organization** is the Ed-Fi abstraction covering state agencies, districts, schools, and other
organizational levels; most instructional and demographic data references one, which is why every
integration credential below is scoped to one or more of them.

## `new-credential`: full reference

```text
Usage: ./new-credential.sh --shape sis|assessment|warehouse --name <name>
                            [--claim-set <name>] [--edorg-ids 1,2,3]

  --shape       Required. sis -> SISVendor, assessment -> AssessmentVendor, warehouse -> DataWarehouse.
  --name        Required. Unique. Letters, digits, '.', '_', '-' only; 1-64 characters.
  --claim-set   Optional override of the claim set implied by --shape. Must already exist in CMS.
  --edorg-ids   Optional comma-separated education organization ids. Defaults depend on --shape and
                the loaded template: the bootstrapped SEA on minimal, the sample LEA on populated, or
                none for warehouse credentials.
```

`new-credential.ps1` accepts the same options as named PowerShell parameters: `-Shape`, `-Name`,
`-ClaimSet`, `-EdOrgIds`, `-Help`.

It registers a new CMS vendor and application, prints the resulting key and secret exactly once (they
cannot be recovered afterward), saves them to `.runtime/credentials/<name>.json`, and makes one
authorized request with the new credential before reporting success -- so a clean run already proves
the credential works, with no further configuration. Reusing an existing `--name` fails without
touching the existing registration (FR-CRED-3). If CMS isn't reachable yet, it fails with a message
telling you to run `start` first (FR-CRED-6).

### Education organization scoping defaults

The default for `--edorg-ids` is derived automatically from **the template actually loaded**
(read from the database's own initialization marker, not from whatever `.env` currently says), not
from a flag you need to pass:

| `--shape` | Template actually loaded | Default `--edorg-ids` |
| --- | --- | --- |
| `sis` or `assessment` | minimal | the bootstrapped SEA, `99` |
| `sis` or `assessment` | populated | the sample LEA, `255901` |
| `warehouse` | either | none (`[]`) |

`DataWarehouse` grants `Read`/`ReadChanges` with no education organization scoping at all (see
[below](#the-data-warehouse-claim-set)), so a warehouse credential doesn't need an education
organization id to read everything it's allowed to read -- `--edorg-ids` for a warehouse credential
is accepted and recorded on the application, but has no effect on what it can actually read, and the
script warns you if you pass one.

Because an SEA-scoped credential reaches every LEA and school beneath it (proven in the Phase 0
spike: an application scoped only to SEA `99` could read and write against all three baseline
schools), scoping a SIS or assessment credential to just the SEA or just the LEA is normally enough
-- you don't need to enumerate every school individually.

### Examples

```shell
# Bash
./new-credential.sh --shape sis --name acme-sis
./new-credential.sh --shape assessment --name acme-assessment --edorg-ids 255901
./new-credential.sh --shape warehouse --name acme-warehouse
./new-credential.sh --shape sis --name acme-sis-school --edorg-ids 990002

# PowerShell
.\new-credential.ps1 -Shape sis -Name acme-sis
.\new-credential.ps1 -Shape assessment -Name acme-assessment -EdOrgIds 255901
.\new-credential.ps1 -Shape warehouse -Name acme-warehouse
```

## Claim sets the kit uses

| Claim set | Standard or kit addition | Used by | Grants |
| --- | --- | --- | --- |
| `EdFiSandbox` | Standard | the bootstrap (admin) credential only | broad access, including creating education organizations; reads people through `RelationshipsWithEdOrgsAndPeople` (not unrestricted) |
| `SISVendor` | Standard | `new-credential --shape sis` | the standard SIS integration permissions |
| `AssessmentVendor` | Standard | `new-credential --shape assessment` | the standard assessment integration permissions |
| `DataWarehouse` | **Kit addition** -- not a standard Ed-Fi claim set | `new-credential --shape warehouse` | `Read` and `ReadChanges` on every resource and descriptor domain, unscoped by education organization; no `Create`/`Update`/`Delete` |

The kit never modifies a standard claim set -- `DataWarehouse` is purely additive.

## The Data Warehouse claim set

No standard Ed-Fi claim set grants broad read access, so `bootstrap/claimsets/DataWarehouse.json`
defines one. It's the exact request body `POST /v3/claimSets/import` uses to create it in CMS,
reviewable in version control (FR-CLAIM-9):

- `Read` and `ReadChanges` -- both with the `NoFurtherAuthorizationRequired` authorization strategy,
  meaning no education organization or relationship scoping is checked at all -- on these claim
  hierarchy roots: `edFiTypes`, `systemDescriptors`, `managedDescriptors`, `educationOrganizations`,
  `people`, `relationshipBasedData`, `assessmentMetadata`, `educationStandards`,
  `primaryRelationships`, `educationContent`, `finance`, `crisisEvent`, `studentHealth`, and
  `snapshot` (publishing). Children inherit from their parent root.
- `ReadChanges` is included deliberately, not just `Read`: it's a separate authorization action that
  gates `/deletes`, `/keyChanges`, and change-query extracts, so a claim set meant for "read
  everything" has to include it or those paths 403 even though plain `GET` succeeds.
- No `Create`, `Update`, or `Delete` on anything, so a warehouse credential cannot mutate the data
  it reads.

**This is a kit invention, not a published Ed-Fi Alliance claim set.** The pilot program is
specifically interested in whether this shape -- read-everything, unscoped by education organization
-- matches what a real downstream data warehouse or analytics integration actually needs, since its
absence from the platform is itself a finding worth confirming. See
[Feedback](../README.md#feedback) in the main README.

It's provisioned once, before DMS starts on a clean start, so a fresh `DataWarehouse` credential's
first request returns `200` immediately rather than the `500` you'd see from DMS's claim-set cache if
a claim set were imported while DMS was already running (see
[Applying a claim set change immediately](../README.md#applying-a-claim-set-change-immediately)).

## The bootstrap credential: file format and lifecycle

`.runtime/bootstrap-credentials.json` (written by `start` or `./bootstrap.sh`/`.ps1`) has this
shape:

```json
{
  "key": "...",
  "secret": "...",
  "claimSetName": "EdFiSandbox",
  "vendorName": "Pilot Kit Bootstrap (ADMIN)",
  "applicationName": "Pilot Kit Bootstrap (ADMIN)",
  "applicationId": 2,
  "educationOrganizationIds": [99],
  "tokenUrl": "https://localhost/api/oauth/token",
  "apiBaseUrl": "https://localhost/api",
  "createdAt": "2026-09-30T15:41:13Z",
  "warning": "ADMIN credential for local testing only. ..."
}
```

It's scoped to the SEA (`educationOrganizationIds: [99]`), which -- as noted above -- is enough to
reach the whole baseline hierarchy beneath it. Re-running `start` or `./bootstrap.sh` reuses this
credential if it still authenticates, and only recreates it (rotating the secret) if the file is
missing, invalid, or the CMS application behind it no longer exists.

### Rotating or removing it

There's no dedicated kit script for this yet. Two options:

- **Remove it entirely**, along with everything else, with a full destructive reset:
  `./reset.sh` / `.ps1` (see [Stopping, resetting, and switching
  templates](../README.md#stopping-resetting-and-switching-templates)). This is the fully verified
  path.
- **Delete just the CMS application record**, using the `PilotKitAdmin` admin token from the claim
  set reload flow (see [Applying a claim set change
  immediately](../README.md#applying-a-claim-set-change-immediately)):

  ```http
  DELETE https://localhost/config/v3/applications/<applicationId>
  Authorization: Bearer <PilotKitAdmin token>
  ```

  using the `applicationId` from `bootstrap-credentials.json` above. Running `./bootstrap.sh` /
  `.ps1` afterward recreates a fresh application and credential (the secret rotates; the vendor
  record itself is left in place). **This path hasn't been verified against a running CMS** -- the
  kit's own code that calls it notes the same -- so if it doesn't behave as expected, fall back to
  the full reset.

## Smoke test and request files

[`http/smoke.http`](../http/smoke.http) and [`http/edorgs.http`](../http/edorgs.http) are the
worked, re-runnable examples referenced from the main README's [setup
steps](../README.md#setup). `edorgs.http` is intended for the **bootstrap** credential specifically
-- a scoped integration credential generally can't create education organizations, and will see a
`403` naming the mismatched education organization id if you try. [`http/claimset-test.http`](../http/claimset-test.http)
is the worked example for the claim-set reload endpoint.
