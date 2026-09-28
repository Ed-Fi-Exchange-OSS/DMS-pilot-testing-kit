# syntax=docker/dockerfile:1

# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Ed-Fi pilot kit "tools" image: the base for the one-shot init containers.
#
# Contents:
#   /opt/tools/api-schema-tools                         EdFi.Api.SchemaTools (.NET tool shim, on PATH)
#   /opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll EdFi.Suite3.BulkLoadClient.Console
#   /usr/local/bin/bulkloadclient                       wrapper: dotnet .../EdFi.BulkLoadClient.Console.dll "$@"
#   curl, jq, psql (postgresql-client), openssl, ca-certificates
#
# Every default below is a pin. See README.md in this directory for provenance and how to bump.

ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0.401-noble@sha256:35d40304542c8689331f8cab17c65926cdf48fe711e289321d71924b230a7d29
ARG DOTNET_RUNTIME_IMAGE=mcr.microsoft.com/dotnet/runtime:10.0.12-noble@sha256:ff17a18b639a0327e52c7c296fa2e1abe6e03eb61d8121a8ef67cc6aa430a27e

# ---------------------------------------------------------------------------------------------
# Stage 1: download the pinned packages, verify their SHA-256, and install them.
# ---------------------------------------------------------------------------------------------
FROM ${DOTNET_SDK_IMAGE} AS build

# NuGet v3 "flat container" (PackageBaseAddress) of the Ed-Fi Azure Artifacts feed. Resolved from
# https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/index.json
ARG EDFI_NUGET_FLAT_BASE=https://pkgs.dev.azure.com/ed-fi-alliance/Ed-Fi-Alliance-OSS/_packaging/EdFi/nuget/v3/flat2
ARG SCHEMATOOLS_VERSION=8.0.1-alpha.0.164
ARG SCHEMATOOLS_SHA256=f44bf7deedc73643a25781250eb9a8f5fd99a4ead9e4838573610b869735c560
ARG BULKLOADCLIENT_VERSION=7.3.20162
ARG BULKLOADCLIENT_SHA256=8149171a717297314a1b3429f59ca67259df9d458f8537fa6fa8d9170cf6390c

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

WORKDIR /pkgs

# Download each .nupkg once and check it against the pinned hash before anything uses it. The
# tool installs below then read only from this local folder, so nothing unverified is installed
# and the feed is contacted exactly once per build.
RUN fetch() { \
        local id="${1,,}" version="${2,,}" sha="$3"; \
        local file="${id}.${version}.nupkg"; \
        if [ -z "$sha" ]; then echo "ERROR: no SHA-256 pin supplied for ${id} ${version}" >&2; exit 1; fi; \
        curl -fsSL --retry 3 --retry-connrefused -o "$file" "${EDFI_NUGET_FLAT_BASE}/${id}/${version}/${file}"; \
        echo "${sha}  ${file}" | sha256sum --check --strict -; \
    }; \
    fetch edfi.api.schematools "$SCHEMATOOLS_VERSION" "$SCHEMATOOLS_SHA256"; \
    fetch edfi.suite3.bulkloadclient.console "$BULKLOADCLIENT_VERSION" "$BULKLOADCLIENT_SHA256"

# SchemaTools: a relocatable --tool-path install (the shim resolves .store relatively), copied
# verbatim into the final stage at the same path. The duplicate .nupkg files NuGet leaves in
# .store (~100 MB) are not needed at run time.
#
# BulkLoadClient: installed the same way only to let NuGet do the extraction, then flattened to
# /opt/bulkloadclient so it can be invoked as `dotnet EdFi.BulkLoadClient.Console.dll`, which is
# how the DMS seed loader runs it.
RUN dotnet tool install edfi.api.schematools \
        --tool-path /opt/tools --version "$SCHEMATOOLS_VERSION" --source /pkgs \
    && find /opt/tools/.store -name '*.nupkg' -delete \
    && dotnet tool install edfi.suite3.bulkloadclient.console \
        --tool-path /tmp/blc --version "$BULKLOADCLIENT_VERSION" --source /pkgs \
    && v="${BULKLOADCLIENT_VERSION,,}" \
    && shopt -s nullglob \
    && dirs=(/tmp/blc/.store/edfi.suite3.bulkloadclient.console/"$v"/edfi.suite3.bulkloadclient.console/"$v"/tools/net*/any) \
    && if [ "${#dirs[@]}" -ne 1 ]; then echo "ERROR: expected one tools/net*/any dir, found ${#dirs[@]}" >&2; exit 1; fi \
    && mkdir -p /opt/bulkloadclient \
    && cp -a "${dirs[0]}/." /opt/bulkloadclient/ \
    && test -f /opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll

# ---------------------------------------------------------------------------------------------
# Stage 2: runtime image. Both tools target net10.0 and need only Microsoft.NETCore.App (see their
# *.runtimeconfig.json), so the smaller dotnet/runtime image is sufficient; no SDK or ASP.NET.
# ---------------------------------------------------------------------------------------------
FROM ${DOTNET_RUNTIME_IMAGE} AS final

ARG DOTNET_RUNTIME_IMAGE
ARG SCHEMATOOLS_VERSION=8.0.1-alpha.0.164
ARG BULKLOADCLIENT_VERSION=7.3.20162

LABEL org.opencontainers.image.title="Ed-Fi pilot kit tools" \
      org.opencontainers.image.description="One-shot init tooling for the Ed-Fi API v8 pilot kit: EdFi.Api.SchemaTools, BulkLoadClient, curl, jq, psql, openssl." \
      org.opencontainers.image.vendor="Ed-Fi Alliance, LLC" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/Ed-Fi-Alliance-OSS/DMS-pilot-testing-kit" \
      org.opencontainers.image.base.name="${DOTNET_RUNTIME_IMAGE}" \
      org.ed-fi.kit.schematools.version="${SCHEMATOOLS_VERSION}" \
      org.ed-fi.kit.bulkloadclient.version="${BULKLOADCLIENT_VERSION}"

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Package versions float within the digest-pinned Ubuntu 24.04 base so that security updates apply;
# pinning exact apt versions breaks as soon as the archive moves on. postgresql-client on noble is
# PostgreSQL 16, matching the kit's database server major version.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        openssl \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/tools /opt/tools
COPY --from=build /opt/bulkloadclient /opt/bulkloadclient
COPY --chmod=0755 bulkloadclient.sh /usr/local/bin/bulkloadclient

ENV PATH="/opt/tools:${PATH}" \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    BULKLOADCLIENT_DLL=/opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll

# Build-time smoke check: proves both tools start on this runtime image (not just on the SDK).
RUN api-schema-tools --version \
    && bulkloadclient --version \
    && psql --version \
    && jq --version

# Non-root: "app" (UID/GID 1654) is created by the .NET runtime-deps base image. BulkLoadClient
# writes logfile.txt and its working files to the current directory, so /work must be writable.
RUN install -d -o 1654 -g 1654 /work
WORKDIR /work
USER 1654:1654

HEALTHCHECK NONE

CMD ["sh"]
