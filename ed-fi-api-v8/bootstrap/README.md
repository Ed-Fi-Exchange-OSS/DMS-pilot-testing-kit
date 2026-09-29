# Baseline education organization hierarchy

`baseline-edorgs.json` is the single source of truth for the kit's baseline education organization
hierarchy (plan.md decision 8, FR-EDORG-14). `init/bootstrap.sh` (Task 10) reads it to create any
missing records on startup, and `http/edorgs.http` (Task 14) must use the same identifiers, grade
levels, and school categories -- the two must never diverge.

## The hierarchy

| Resource | ID field | ID | Name | References |
| --- | --- | --- | --- | --- |
| `stateEducationAgencies` | `stateEducationAgencyId` | `99` | Pilot Kit State Education Agency | -- |
| `localEducationAgencies` | `localEducationAgencyId` | `9900` | Pilot Kit Local Education Agency | SEA `99` |
| `schools` | `schoolId` | `990001` | Pilot Kit Elementary School | LEA `9900` |
| `schools` | `schoolId` | `990002` | Pilot Kit Middle School | LEA `9900` |
| `schools` | `schoolId` | `990003` | Pilot Kit High School | LEA `9900` |

Exactly five records (FR-EDORG-2), in dependency order so every reference target exists before the
record referencing it (FR-EDORG-3): the SEA, then the LEA, then the three schools.

Each school carries grade levels consistent with its level (FR-EDORG-4):

| School | Grade levels | School category |
| --- | --- | --- |
| Elementary (`990001`) | Kindergarten - Fifth grade | Elementary School |
| Middle (`990002`) | Sixth grade - Eighth grade | Middle School |
| High (`990003`) | Ninth grade - Twelfth grade | High School |

These IDs are fixed and documented (FR-EDORG-7) and were chosen not to collide with the populated
template's sample education organizations -- `255901`, `255950`, `6000203`, `19255901`, and the
sample schools under LEA `255901` (FR-EDORG-8; the spike confirmed both hierarchies coexist,
spike-notes.md Q9).

## Descriptor values

Every `*Descriptor` value in `baseline-edorgs.json` was checked against the real Data Standard 5.2
descriptor XML (`Descriptors/*.xml` in the `v5.2.0` tag of
`Ed-Fi-Alliance-OSS/Ed-Fi-Data-Standard`, the same source `init/template.sh` loads -- FR-EDORG-5), not
assumed from convention:

- `EducationOrganizationCategoryDescriptor`: `State Education Agency`, `Local Education Agency`, `School`
- `LocalEducationAgencyCategoryDescriptor`: `Regular public school district`
- `SchoolCategoryDescriptor`: `Elementary School`, `Middle School`, `High School`
- `GradeLevelDescriptor`: `Kindergarten`, `First grade` ... `Twelfth grade`

Every one of these `CodeValue`/`Namespace` pairs exists in the pinned Data Standard version, so the
file succeeds against a freshly initialized minimal-template environment with no preparation beyond
startup. If `DATA_STANDARD_VERSION` in `.env.example` is ever bumped, re-check this list against the
new tag's `Descriptors/*.xml` before changing it.

## Shape

Each entry is `{resource, naturalKey, body}`:

- `resource`: the DMS resource collection name, for example `schools`.
- `naturalKey`: the fields `init/bootstrap.sh` uses for a `GET ${DMS_BASE_URL}/data/ed-fi/<resource>?<naturalKey>`
  existence check before deciding whether to `POST` (DMS has no upsert for these resources).
- `body`: the exact `POST` body, in DS 5.2 field names.

`init/bootstrap.sh` loops over the array generically and processes entries in file order, so adding
a resource type only requires the loop to already know how to build a query string from `naturalKey`
(it does, for any flat object of scalar values) -- no code change needed for a new *education
organization* type that also uses a single scalar natural key field.

## Adding more organizations

Append an entry after the existing five, keeping every reference target earlier in the array than
the record that references it. For example, a second LEA under the same SEA:

```json
{
  "resource": "localEducationAgencies",
  "naturalKey": { "localEducationAgencyId": 9901 },
  "body": {
    "localEducationAgencyId": 9901,
    "nameOfInstitution": "A Second Pilot Kit Local Education Agency",
    "localEducationAgencyCategoryDescriptor": "uri://ed-fi.org/LocalEducationAgencyCategoryDescriptor#Regular public school district",
    "categories": [
      { "educationOrganizationCategoryDescriptor": "uri://ed-fi.org/EducationOrganizationCategoryDescriptor#Local Education Agency" }
    ],
    "stateEducationAgencyReference": { "stateEducationAgencyId": 99 }
  }
}
```

DS 5.2 names the category array differently by resource: `categories` on state and local education
agencies, but `educationOrganizationCategories` on schools. DMS rejects the wrong one with HTTP 400
(`categories is required`).

Pick an ID that doesn't collide with an existing baseline or populated-template ID. Update
`http/edorgs.http` (Task 14) to match -- its consistency check compares the two files' identifiers.

## Bootstrapping behavior

`init/bootstrap.sh` creates the "Pilot Kit Bootstrap (ADMIN)" vendor and an `EdFiSandbox`
application scoped to the SEA (id `99`, read from this file, not hard-coded), because the SEA scope
reaches its LEA and schools too (spike-notes.md Q7). It is idempotent: re-running it recreates only
the records that are missing, and reuses the existing bootstrap credential when it still
authenticates (FR-BOOT-4/5). See `init/bootstrap.sh`'s header comment for the full credential
reuse/rotation decision, and the kit's top-level docs for how to remove this administrative
credential once you no longer need it (FR-BOOT-13).
