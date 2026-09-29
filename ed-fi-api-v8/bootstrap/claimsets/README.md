# Bootstrap claim sets

Each `*.json` file here is the exact request body `init/claimsets.sh` (Task 11) sends to
`POST {CONFIG_BASE_URL}/v3/claimSets/import` on CMS: `{claimSetName, resourceClaims[]}`, the same
shape `GET /v3/claimSets/{id}/export` returns. JSON can't carry comments, so this file documents
intent that the files themselves cannot.

## `DataWarehouse.json`

A **kit addition, not an Ed-Fi standard claim set** (it is not one of the 14 claim sets embedded in
CMS -- `SISVendor`, `EdFiSandbox`, `RosterVendor`, and so on -- all of which are `_isSystemReserved`
and untouched by this file).

It grants `Read` on every top-level branch of the DS 5.2 claims hierarchy: all resources, all
descriptors, education organizations, and people (students, staff, contacts), with
`NoFurtherAuthorizationRequired` so reads are **not scoped by education organization**. A
DataWarehouse credential therefore needs no `educationOrganizationIds`. It grants **no Create,
Update, or Delete** anywhere -- this is a read-only reporting/extract role, not a data-loading
vendor.

`ReadChanges` is granted alongside `Read` on every branch because it is a *separate* action in this
build, not implied by `Read`. It gates `/deletes`, `/keyChanges`, and change-query reads
(`?minChangeVersion=`). A "read everything" warehouse role that omitted it would get 403s on every
`/deletes` endpoint and on incremental extracts, which defeats the purpose of a change-data-capture
consumer.

### The 14 roots, and the 2 left out

The DS 5.2 claims hierarchy has 16 root claims. This file grants Read and ReadChanges on 14 of
them and deliberately excludes:

- `services/identity` -- a service capability (managing CMS identity/registration), not education
  data. A warehouse has no business reading or being scoped by it.
- `domains/tpdm` -- the TPDM extension is not loaded in this kit (`ClaimsOptions__DataStandardVersion`
  is DS 5.2 only), so granting it would be inert at best and misleading in a reviewable file.

Children inherit their grant from whichever root they hang off, so listing only the 14 roots is
enough to cover every resource and descriptor under them.

### Where each root's `name` and `claimName` came from

Every `claimName` below was read directly from the Data Management Service source, not guessed:
`src/config/backend/EdFi.DmsConfigurationService.Backend/Claims/Standards/ds52/Claims.json` in
`Ed-Fi-Alliance-OSS/Data-Management-Service` (`main` branch, fetched 2026-09-29) lists 16 root
entries under `claimsHierarchy`; this file uses all but the two above. Each root's short `name` is
derived the same way CMS itself derives it for `/v3/claimSets/{id}/export`
(`ClaimSetRepository.BuildResourceClaims` -> `GetLeafName`, in
`src/config/backend/EdFi.DmsConfigurationService.Backend.Postgresql/Repositories/ClaimSetRepository.cs`):
the substring of `claimName` after its last `/`. Both are therefore confirmed against upstream
source, not the conventional-pattern fallback the task allowed.

| `name` | `claimName` |
| --- | --- |
| `edFiTypes` | `http://ed-fi.org/identity/claims/domains/edFiTypes` |
| `systemDescriptors` | `http://ed-fi.org/identity/claims/domains/systemDescriptors` |
| `managedDescriptors` | `http://ed-fi.org/identity/claims/domains/managedDescriptors` |
| `educationOrganizations` | `http://ed-fi.org/identity/claims/domains/educationOrganizations` |
| `people` | `http://ed-fi.org/identity/claims/domains/people` |
| `relationshipBasedData` | `http://ed-fi.org/identity/claims/domains/relationshipBasedData` |
| `assessmentMetadata` | `http://ed-fi.org/identity/claims/domains/assessmentMetadata` |
| `educationStandards` | `http://ed-fi.org/identity/claims/domains/educationStandards` |
| `primaryRelationships` | `http://ed-fi.org/identity/claims/domains/primaryRelationships` |
| `educationContent` | `http://ed-fi.org/identity/claims/ed-fi/educationContent` |
| `finance` | `http://ed-fi.org/identity/claims/domains/finance` |
| `crisisEvent` | `http://ed-fi.org/identity/claims/ed-fi/crisisEvent` |
| `studentHealth` | `http://ed-fi.org/identity/claims/ed-fi/studentHealth` |
| `snapshot` | `http://ed-fi.org/identity/claims/publishing/snapshot` |

`init/claimsets.sh` is still the runtime guard: CMS reports any unrecognized `claimName` as a
non-empty `warnings` array on import, and the script fails rather than accept a partial grant
(spike-notes Q6).

## Adding another file

`init/claimsets.sh` imports every `*.json` file in this directory, in name order. A new file needs
only `claimSetName` and a `resourceClaims` array in the same shape; the script validates both are
present before calling CMS.

## Applying claim set changes immediately

DMS caches claim sets for up to 10 minutes (`ClaimSetsCacheExpirationSeconds`). A credential using a
claim set that was just imported or changed while DMS was already running gets HTTP 500 "No security
metadata has been configured for this resource" until that cache refreshes -- unless the cache is
forced to reload first (Task 18, FR-CLAIM-14). `init/claimsets.sh` does this automatically for the
files in this directory (see `reload_claim_set_if_running` there); this section is for reloading
after a manual change made straight through CMS's API.

Get a token for **PilotKitAdmin** (the kit's administrative CMS client; its secret is
`CMS_ADMIN_CLIENT_SECRET` in `.env`) directly from CMS -- an ordinary integration credential cannot
call this endpoint (see below):

```sh
TOKEN=$(curl -sk -X POST https://localhost/config/connect/token \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode client_id=PilotKitAdmin \
    --data-urlencode client_secret="$CMS_ADMIN_CLIENT_SECRET" \
    --data-urlencode scope=edfi_admin_api/full_access \
    | jq -r .access_token)
```

Then call the reload endpoint:

```sh
curl -k -X POST https://localhost/api/management/reload-claimsets \
    -H "Authorization: Bearer $TOKEN"
```

A success response is `200` with `{"message": "Claimsets reloaded successfully"}`. Requests without
a valid bearer token get `401`; a valid token that lacks the required role (only PilotKitAdmin has
it -- see `init/identity.sh`, and note that a participant integration credential's `dms-client` role
is never enough) gets `403`. With `DMS_CLAIMSET_RELOAD_ENABLED=false` in `.env`, the endpoint is not
mapped at all and every request gets `404`, whatever the credential.
