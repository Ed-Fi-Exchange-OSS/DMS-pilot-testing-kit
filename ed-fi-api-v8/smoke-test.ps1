# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

#Requires -Version 7

<#
.SYNOPSIS
    Runs the kit's non-interactive smoke test (Task 14).

.DESCRIPTION
    Host wrapper for init/smoke-test.sh, independent of Task 12's start/stop/reset/bootstrap scripts
    and Task 13's new-credential. Runs the smoke test inside the tools container, through NGINX, so
    routing and TLS are exercised too (not just DMS directly):
        docker compose run --rm --no-deps --user 0:0 tools sh /init/smoke-test.sh
    --no-deps so a stopped stack fails with "run start first" instead of being started. The tools
    service mounts http/ read-only for the edorgs.http consistency check (FR-EDORG-14). This
    script's exit code is the container's. -DebugCredentials is passed in as SMOKE_TEST_DEBUG=1
    (docker compose run -e).

    Exercises the same requests http/smoke.http documents: a token, Discovery, a descriptor read, a
    write and read-back, offset/limit and cursor paging, a change-query extract, an ETag update plus
    a stale-ETag 412, a deliberately invalid request, and (on the populated template only) an
    assessment-style reference write. Prints one PASS/FAIL/SKIP line per step and a summary, and
    exits non-zero if any step failed.

.PARAMETER CheckEdorgsOnly
    Only run the http/edorgs.http vs bootstrap/baseline-edorgs.json consistency check (FR-EDORG-14)
    and exit -- skips every DMS/NGINX request.

.PARAMETER DebugCredentials
    Print each client key/secret pair the smoke test reads or creates, to help diagnose
    authorization failures. WARNING: this prints live secrets; do not share the output. Named this
    way because -Debug is a PowerShell common parameter (added by [CmdletBinding()]) with its own
    meaning, so it can't be redefined here.

.EXAMPLE
    ./smoke-test.ps1

.EXAMPLE
    ./smoke-test.ps1 -CheckEdorgsOnly

.EXAMPLE
    ./smoke-test.ps1 -DebugCredentials
#>

[CmdletBinding()]
param(
    [switch]$CheckEdorgsOnly,

    [switch]$DebugCredentials,

    [Alias('h')]
    [switch]$Help
)

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $ScriptDir
try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker does not appear to be running. Start Docker Desktop and try again."
        exit 1
    }

    if (-not (Test-Path (Join-Path $ScriptDir '.env'))) {
        Write-Error ".env not found in $ScriptDir. Copy .env.example to .env first, then run start."
        exit 1
    }

    docker image inspect edfi-pilot-tools:local *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "The tools image (edfi-pilot-tools:local) has not been built yet: run start first."
        exit 1
    }

    if ($CheckEdorgsOnly) {
        docker compose run --rm --no-deps --user 0:0 tools sh /init/check-edorgs-http.sh
        exit $LASTEXITCODE
    }

    $credFile = Join-Path $ScriptDir '.runtime/bootstrap-credentials.json'
    if (-not (Test-Path $credFile)) {
        Write-Error (".runtime/bootstrap-credentials.json not found in $ScriptDir. Run start first " +
            "(or ./bootstrap.ps1 if the stack is already up).")
        exit 1
    }

    $debugFlag = if ($DebugCredentials) { '1' } else { '0' }
    docker compose run --rm --no-deps --user 0:0 -e "SMOKE_TEST_DEBUG=$debugFlag" tools `
        sh /init/smoke-test.sh
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
