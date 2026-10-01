# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
.SYNOPSIS
    Reruns bootstrapping against a running Ed-Fi API v8 pilot kit (Task 12).

.DESCRIPTION
    Reruns bootstrapping (the bootstrap credential and the baseline education organization
    hierarchy, init/bootstrap.sh) against an already-running stack, without a destructive reset
    (FR-BOOT-10): docker compose run --rm init-bootstrap.

    Requires the stack to already be started (start.ps1); `docker compose run` would otherwise start
    every dependency on its own, so this checks first and fails with a clear message instead.

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    ./bootstrap.ps1
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

if (-not (Test-KitStackRunning -Service 'dms')) {
    Stop-KitWithError 'the stack is not running. Run ./start.ps1 first, then ./bootstrap.ps1.'
}

Invoke-KitCompose run --rm init-bootstrap
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-KitLog ''
Write-KitLog 'Bootstrap complete.'
Write-KitLog "Credentials: $(Join-Path $KitDir '.runtime/bootstrap-credentials.json')"
