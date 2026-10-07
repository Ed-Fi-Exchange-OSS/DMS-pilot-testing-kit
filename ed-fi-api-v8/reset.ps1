# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

#Requires -Version 7

<#
.SYNOPSIS
    DESTRUCTIVE: resets the Ed-Fi API v8 pilot kit to a clean state (Task 12).

.DESCRIPTION
    The kit's explicit, clearly labelled destructive reset (FR-LIFE-6). Removes every persisted
    volume (the database, the ApiSchema volume, the Data Standard download cache, and pgAdmin's
    data) and every file under .runtime/ except .runtime/.gitkeep -- the bootstrap credentials and
    any provisioned integration credentials become invalid. Keeps .env and the TLS certificate
    (ssl/server.crt, ssl/server.key): only data, not configuration, is destroyed.

    Runs: docker compose down -v --remove-orphans

    Without -Force, this prompts for confirmation and shows exactly what will be removed. Answering
    anything other than "yes" -- or running without -Force with no terminal attached to ask --
    changes nothing and exits non-zero.

.PARAMETER Force
    Skip the interactive confirmation (for scripts and CI).

.PARAMETER Start
    After resetting, run start.ps1.

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    ./reset.ps1

.EXAMPLE
    ./reset.ps1 -Force -Start
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $Start,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Help) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'scripts/lib.ps1')

Assert-KitDockerRunning
Assert-KitComposeAvailable

if (-not $Force) {
    $isInteractive = [Environment]::UserInteractive -and -not ([Console]::IsInputRedirected)
    if (-not $isInteractive) {
        Stop-KitWithError 'no terminal attached to confirm. Re-run with -Force to reset non-interactively.'
    }
    $project = Get-KitEnvValue -Name 'KIT_PROJECT_NAME' -Default 'edfi-pilot'
    Write-KitLog "This permanently deletes, for project '$project':"
    Write-KitLog ('  - the PostgreSQL database volume: all DMS and CMS data, including anything ' +
        'bootstrapped or written since the last reset')
    Write-KitLog '  - the ApiSchema volume'
    Write-KitLog '  - the Data Standard download cache'
    Write-KitLog "  - pgAdmin's data volume"
    Write-KitLog ("  - every file under $(Join-Path $KitDir '.runtime') except .gitkeep -- the " +
        'bootstrap credentials and any provisioned integration credentials in ' +
        '.runtime/credentials/ become invalid')
    Write-KitLog ''
    Write-KitLog '.env and the TLS certificate (ssl/server.crt, ssl/server.key) are kept.'
    Write-KitLog ''
    Write-KitLog 'Runs: docker compose down -v --remove-orphans'
    $confirm = Read-Host 'Type "yes" to continue'
    if ($confirm -ne 'yes') {
        Write-KitLog 'Not confirmed. Nothing was changed.'
        exit 1
    }
}

Invoke-KitCompose down -v --remove-orphans
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$runtimeDir = Join-Path $KitDir '.runtime'
if (Test-Path -LiteralPath $runtimeDir) {
    Get-ChildItem -LiteralPath $runtimeDir -Force | Where-Object { $_.Name -ne '.gitkeep' } |
        Remove-Item -Recurse -Force
}

Write-KitLog ''
Write-KitLog 'Reset complete. .env and the TLS certificate were kept.'

if ($Start) {
    Write-KitLog ''
    Write-KitLog 'Starting the stack again (-Start)...'
    & (Join-Path $KitDir 'start.ps1')
    exit $LASTEXITCODE
}
