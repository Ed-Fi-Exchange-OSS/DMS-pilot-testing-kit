# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
.SYNOPSIS
    Stops the Ed-Fi API v8 pilot kit (Task 12).

.DESCRIPTION
    Stops the stack (docker compose stop) without touching any persisted data (FR-LIFE-5). All
    persisted data -- the database, the ApiSchema volume, the Data Standard cache, and pgAdmin's
    data -- is kept. Start it again with start.ps1.

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    ./stop.ps1
#>
[CmdletBinding()]
param(
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

Invoke-KitCompose stop
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-KitLog ''
Write-KitLog 'Stack stopped. Persisted data was kept.'
Write-KitLog 'Start it again with: ./start.ps1'
