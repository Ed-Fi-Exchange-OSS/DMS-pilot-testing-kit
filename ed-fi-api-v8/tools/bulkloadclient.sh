#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

# Installed in the tools image as /usr/local/bin/bulkloadclient. Equivalent to
# `dotnet EdFi.BulkLoadClient.Console.dll "$@"`, which is how the DMS seed loader invokes it.
set -eu
exec dotnet "${BULKLOADCLIENT_DLL:-/opt/bulkloadclient/EdFi.BulkLoadClient.Console.dll}" "$@"
