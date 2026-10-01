# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
.SYNOPSIS
    Provisions a participant integration credential (Task 13).

.DESCRIPTION
    Host wrapper for init/new-credential.sh, independent of Task 12's start/stop/reset/bootstrap
    scripts. Validates arguments locally for fast feedback, then hands them, unmodified, to
    init/new-credential.sh inside the tools container:
        docker compose run --rm --no-deps --user 0:0 tools sh /init/new-credential.sh ...
    --no-deps so a stopped stack fails with "run start first" instead of being started; --user 0:0 so
    the container can write .runtime/credentials/. This script's own exit code is whatever that
    container exits with.

.PARAMETER Shape
    Required. sis -> SISVendor, assessment -> AssessmentVendor, warehouse -> DataWarehouse.

.PARAMETER Name
    Required. Unique. Letters, digits, '.', '_', '-' only; 1-64 characters.

.PARAMETER ClaimSet
    Optional override of the claim set implied by -Shape. Must already exist in CMS.

.PARAMETER EdOrgIds
    Optional comma-separated education organization ids. Defaults depend on -Shape and the loaded
    template: the bootstrapped SEA on minimal, the sample LEA on populated, or none for warehouse
    credentials.

.EXAMPLE
    ./new-credential.ps1 -Shape sis -Name acme-sis

.EXAMPLE
    ./new-credential.ps1 -Shape warehouse -Name acme.warehouse-01
#>

[CmdletBinding()]
param(
    [ValidateSet('sis', 'assessment', 'warehouse')]
    [string]$Shape,

    [string]$Name,

    [string]$ClaimSet,

    [string]$EdOrgIds,

    [Alias('h')]
    [switch]$Help
)

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

if (-not $Shape) {
    Write-Error "-Shape is required: sis, assessment, or warehouse"
    exit 1
}

if (-not $Name) {
    Write-Error "-Name is required"
    exit 1
}
if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Error "-Name may contain only letters, digits, '.', '_', and '-' (got '$Name')"
    exit 1
}
if ($Name.Length -lt 1 -or $Name.Length -gt 64) {
    Write-Error "-Name must be 1-64 characters (got $($Name.Length))"
    exit 1
}

if ($EdOrgIds -and $EdOrgIds -notmatch '^[0-9]+(,[0-9]+)*$') {
    Write-Error "-EdOrgIds must be a comma-separated list of numbers (got '$EdOrgIds')"
    exit 1
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

    $containerArgs = @('--shape', $Shape, '--name', $Name)
    if ($ClaimSet) {
        $containerArgs += @('--claim-set', $ClaimSet)
    }
    if ($EdOrgIds) {
        $containerArgs += @('--edorg-ids', $EdOrgIds)
    }

    docker compose run --rm --no-deps --user 0:0 tools sh /init/new-credential.sh @containerArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
