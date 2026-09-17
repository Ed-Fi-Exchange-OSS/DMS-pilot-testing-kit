# PRD for the SIS Pilot Testing Kit

## Loose Notes / Braindump

Conformance testing will be performed on systems configured for Ed-Fi Data
Standard 5.2 with the following features available:

- All endpoints that support the Discovery API, Resource API, and Descriptor API
- Metadata (XSD, OpenAPI, Swagger UI)
- Change queries
- Profiles
- ETags
- Limit / offset paging
- Standard claimsets

The database will be initialized with the "minimal template" setup - no
additional sample data.

Keep the compose setup as simple and clean as possible, but do use NGiNX.

Configure rate limiting as optional. In the DMS, add a rewrite rule (optional?)
to redirect `/data/v3` to the new paths. Find out if vendors are prepared for
the new paths

Provide a .http file with some simple test instructions to prove out the
interactions.
