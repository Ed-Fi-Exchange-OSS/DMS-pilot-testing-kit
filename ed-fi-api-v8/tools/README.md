# Kit tools image

`ed-fi-api-v8/tools/Dockerfile` builds the local `tools` image used by the kit's one-shot init
containers (schema provisioning, template loading, and later bootstrap and credential scripts).
Compose builds it on first `up`; participants need no host .NET SDK.

## What's inside

| Path / command | What it is |
| --- | --- |
| `api-schema-tools` (on `PATH`, `/opt/tools`) | `EdFi.Api.SchemaTools` .NET tool: `hash`, `ddl emit`, `ddl provision`, `cdc` |
| `/opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll` | `EdFi.Suite3.BulkLoadClient.Console`, flattened from the tool package |
| `bulkloadclient` (`/usr/local/bin`) | Wrapper for `dotnet /opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll "$@"` |
| `curl`, `jq`, `psql`, `openssl`, `ca-certificates` | From Ubuntu 24.04 apt; `psql` is PostgreSQL 16 |
| `BULKLOADCLIENT_DLL` env var | Path of the BulkLoadClient DLL, for scripts that prefer `dotnet "$BULKLOADCLIENT_DLL"` |

The image runs as the non-root `app` user (UID/GID 1654, from the .NET base image), in `WORKDIR
/work`, and defaults to `CMD ["sh"]`. There is no `ENTRYPOINT`, so a Compose service can run
`command: ["sh", "/init/provision-schema.sh"]` or similar. `HEALTHCHECK NONE`: these are one-shot
containers gated with `service_completed_successfully`.

### Build stages

1. **`build`** (`dotnet/sdk`): downloads both `.nupkg` files once from the Ed-Fi feed, checks each
   against a pinned SHA-256, then runs `dotnet tool install --tool-path` from that local folder only.
   Nothing unverified is installed, and nuget.org is never contacted. Both tool packages carry all
   their dependencies.
2. **`final`** (`dotnet/runtime`): copies `/opt/tools` and `/opt/bulkloadclient`, installs the apt
   tools, and runs `api-schema-tools --version` and `bulkloadclient --version` as a build-time
   smoke check. The check proves that both tools start on the runtime-only image.

Both packages target `net10.0` and their `*.runtimeconfig.json` require only
`Microsoft.NETCore.App` 10.0.0. They need neither ASP.NET Core nor the SDK, so `dotnet/runtime:10.0`
is the correct and smallest base. On top of the runtime base, the tools add about 150 MB (SchemaTools
127 MB after pruning the cached `.nupkg` copies, BulkLoadClient 22 MB) plus the apt packages. An
SDK-based final image would be roughly 800 MB before any tools.

No proxy or feed-credential configuration is needed: the Ed-Fi feed is public, and builds run on
participant machines with their normal network.

## Pins (resolved 2026-09-28)

| Build arg | Default | Source |
| --- | --- | --- |
| `DOTNET_SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0.401-noble@sha256:35d40304542c8689331f8cab17c65926cdf48fe711e289321d71924b230a7d29` | MCR registry v2 manifest list (amd64, arm, arm64); same digest as `10.0-noble` on that date |
| `DOTNET_RUNTIME_IMAGE` | `mcr.microsoft.com/dotnet/runtime:10.0.12-noble@sha256:ff17a18b639a0327e52c7c296fa2e1abe6e03eb61d8121a8ef67cc6aa430a27e` | Same; same digest as `10.0-noble` |
| `EDFI_NUGET_FLAT_BASE` | `https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/flat2` | `PackageBaseAddress/3.0.0` from the feed's `index.json` |
| `SCHEMATOOLS_VERSION` | `8.0.1-alpha.0.164` | Matches the DMS image `edfialliance/ed-fi-api:8.0.1-alpha.0.164` (plan Decision 2); newest version on the feed on that date |
| `SCHEMATOOLS_SHA256` | `f44bf7deedc73643a25781250eb9a8f5fd99a4ead9e4838573610b869735c560` | `sha256sum` of the downloaded `.nupkg` |
| `BULKLOADCLIENT_VERSION` | `7.3.20162` | `$PinnedBulkLoadClientVersion` in DMS `eng/Package-Management.psm1` at commit `0abbaf2c`, which is the source commit of SchemaTools `8.0.1-alpha.0.164` (from its nuspec) |
| `BULKLOADCLIENT_SHA256` | `8149171a717297314a1b3429f59ca67259df9d458f8537fa6fa8d9170cf6390c` | `sha256sum` of the downloaded `.nupkg` |

Why Ubuntu rather than Debian: .NET 10's default Linux images are Ubuntu 24.04 (`noble`), and MCR
publishes no GA Debian (`bookworm`/`trixie`) tags for .NET 10. The SDK `10.0.401` is built on runtime
`10.0.12`, so the two stages share the same runtime patch level.

The feed also carries BulkLoadClient `7.3.20185` (newer). It is not used, because the DMS repo pins
`7.3.20162` and reviews bumps against the loader's flag preflight (`-b -d -w -k -s -o -x`).

## Package facts (from inspecting the `.nupkg` files)

### EdFi.Api.SchemaTools 8.0.1-alpha.0.164

- Tool command `api-schema-tools` (`DotnetToolSettings.xml`, entry point `api-schema-tools.dll`); layout `tools/net10.0/any`
- Source commit `0abbaf2c2178d2ff0379b4cb3214df33df4da744`; license Apache-2.0
- `ddl provision` (from `api-schema-tools ddl provision --help`):

  ```text
  -s, --schema <path>              (required, repeatable) first is core, rest are extensions
  -c, --connection-string <cs>     (required) ADO.NET (Npgsql) connection string
  -d, --dialect <pgsql|mssql>      (required)
  --create-database                create the target database if missing
  -t, --timeout <seconds>          default 300
  --managed-state-path ...         CDC-managed provisioning only; the kit does not use it
  -v, --verbose
  ```

  The kit's invocation (without CDC), mirroring `provision-dms-schema.ps1`, is:

  ```sh
  api-schema-tools ddl provision \
    --schema /apischema/ApiSchema.json \
    --connection-string "Host=db;Port=5432;Database=${POSTGRES_DB_NAME};Username=postgres;Password=${POSTGRES_PASSWORD}" \
    --dialect pgsql --create-database
  ```

  The tool reads no environment variables for this command; everything goes through flags. It runs
  the DDL in one transaction. It is create-only: a same-hash re-run is safe and preserves data, while
  a different hash or a partial state fails with "Drop and recreate the database". PostgreSQL
  provisioning needs rights to create the `NOLOGIN` role `edfi_dms_enqueue_owner`, so connect as a
  superuser (`postgres`).
- `hash <coreSchemaPath> [extensionSchemaPath...]` prints `Effective schema hash: <sha256>` on
  **stdout**, with Serilog lines on **stderr**. Against `EdFi.DataStandard52.ApiSchema` 1.0.335 it
  returned `a0d39468ef30d3e99273065256bfffa42b799404ca5fbc09a8648f349d9217e1`, and `ddl emit -d pgsql`
  produced a 4.7 MB `pgsql.sql`. These were run locally on the host .NET 10 runtime, not in the image.

### EdFi.Suite3.BulkLoadClient.Console 7.3.20162

- Also a .NET tool package (command `EdFi.BulkLoadClient.Console`); layout `tools/net10.0/any`
- Source commit `e907fe5746468a45e4cd7e7542d2912690cac7d1` (Ed-Fi-ODS)
- The DMS seed loader invokes it as `dotnet EdFi.BulkLoadClient.Console.dll` with
  `-b <dmsBaseUrl> -d <dataDir> -w <workDir> -k <key> -s <secret> -o <oauthUrl> -x <xsdDir> -c 10 -l 10 -t 5 -r 2`.
  The low concurrency (`-c 10 -l 10 -t 5 -r 2`) avoids tripping DMS's circuit breaker.
- Writes `logfile.txt` (log4net `RollingAppender`) to the current directory, so run it from `/work`
  or a mounted writable directory.

## Bumping a version

1. Pick the version, for example SchemaTools to match a new DMS image tag.
2. Get the hash, replacing `<id>` and `<ver>` with the lowercase values:

   ```sh
   base=https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/flat2
   curl -fsSL "$base/<id>/<ver>/<id>.<ver>.nupkg" | sha256sum
   ```

   To list available versions, run `curl -fsSL "$base/<id>/index.json" | jq .versions`.
3. Update the `ARG` defaults here, or override them through the Compose `build.args` / `.env`. The
   version and its SHA-256 must change together; the build fails if a hash is missing or wrong.
4. For base images, resolve the new tag's manifest-list digest:

   ```sh
   curl -sI -H 'Accept: application/vnd.oci.image.index.v1+json' \
     -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
     https://mcr.microsoft.com/v2/dotnet/runtime/manifests/10.0-noble | grep -i docker-content-digest
   ```

   Keep the SDK and runtime images on the same .NET runtime patch level.
5. Rebuild with `docker compose build tools` and confirm the build-time smoke check passes.

## Not yet verified (for the Task 1 spike)

This environment had no Docker daemon. The Dockerfile passes `hadolint` 2.15.1 with no findings; older releases such as 2.12.0 report
`DL3006` on the `ARG`-based `FROM` lines, a false positive because the images are digest-pinned. Its
build-stage shell logic (download, hash check, tool install, and flatten) was run locally with the
same commands, and both tools ran on a host .NET 10.0.11 runtime. Still unproven:

- [ ] The image builds, and the final-stage smoke check passes on `dotnet/runtime:10.0.12-noble`, on
      both amd64 and arm64 hosts
- [ ] The relocated `/opt/tools/api-schema-tools` shim finds the runtime in `/usr/share/dotnet`
      (`DOTNET_ROOT` is set defensively)
- [ ] `ddl provision` against the kit's `postgres:16` container produces a schema that the DMS
      `8.0.1-alpha.0.164` image accepts (DMS stops returning 503)
- [ ] `ddl provision` works as a non-superuser if the kit ever stops using `postgres`
      (`edfi_dms_enqueue_owner` role creation)
- [ ] BulkLoadClient `7.3.20162` loads DS 5.2 `Descriptors/` through the NGINX or direct DMS URL
      from this image, and the pin still matches the DMS repo at the time of the pilot
- [ ] UID 1654 can write to any bind-mounted output directory on Linux hosts (for example
      `.runtime/`); if not, the Compose service may need `user:` overrides
