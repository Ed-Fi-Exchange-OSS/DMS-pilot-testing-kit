# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
.SYNOPSIS
    Starts the Ed-Fi API v8 pilot kit (Task 12).

.DESCRIPTION
    A thin wrapper around `docker compose up`; the actual initialization work happens in the
    one-shot containers under init/ (compose.init.yml). Same parameters and observable behavior as
    start.sh (FR-LIFE-2/3).

    1. Checks that Docker is running and Compose 2.20 or later is available.
    2. Creates .env from .env.example with freshly generated local secrets, if .env doesn't exist
       yet (an existing .env is never modified; missing variables are only reported).
    3. Generates a local, self-signed TLS certificate under ssl/, if one doesn't exist yet.
    4. Creates .runtime/ and the NGINX log directory, if needed.
    5. Runs `docker compose up -d --build --wait`.

    On success, prints the kit's URLs, the template actually in use, and the bootstrap credentials
    file path. On failure, shows Compose's own error, names the service(s) that failed, shows their
    recent logs, prints the exact `docker compose logs <service>` command, and exits non-zero.
    Running this again against an already-running stack exits 0 and makes no changes.

.PARAMETER Template
    Set DATABASE_TEMPLATE in .env before starting: 'minimal' or 'populated'. Only takes effect on a
    database that has not been initialized yet -- changing it on an existing database requires
    reset.ps1 (see reset.ps1 -Help).

.PARAMETER Help
    Show this help and exit.

.EXAMPLE
    ./start.ps1

.EXAMPLE
    ./start.ps1 -Template populated
#>
[CmdletBinding()]
param(
    [ValidateSet('minimal', 'populated')]
    [string] $Template,

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
Initialize-KitEnvFile

if ($Template) {
    $previous = Get-KitEnvValue -Name 'DATABASE_TEMPLATE' -Default 'minimal'
    Set-KitEnvValue -Name 'DATABASE_TEMPLATE' -Value $Template
    if ($previous -ne $Template) {
        Write-KitLog "DATABASE_TEMPLATE set to '$Template' in .env."
        Write-KitLog 'This only affects a database that has not been initialized yet: if one already'
        Write-KitLog 'exists with a different template, init-template will warn and skip instead of'
        Write-KitLog "reloading. Run './reset.ps1 -Start' to switch templates on existing data."
    }
}

Initialize-KitCertificates
Initialize-KitDirectories

Write-KitLog 'Starting the stack (docker compose up -d --build --wait).'
Write-KitLog 'This can take a few minutes on first run: image pulls, the tools image build, schema'
Write-KitLog 'provisioning, and the template load all happen before this command returns.'

# Compose's own `--wait` error (for example "container ... has no healthcheck configured") is often
# the only statement of what went wrong, so its output is captured, as well as streamed, for the
# failure report.
$upOutput = @(Invoke-KitComposeTee up -d --build --wait)
if ($LASTEXITCODE -ne 0) {
    Show-KitUpFailure -UpOutput $upOutput
    exit 1
}

Write-KitLog ''
Write-KitLog 'Ed-Fi API v8 pilot kit is up.'
Write-KitLog ''
Show-KitUrls
Write-KitLog ''
Write-KitLog "Template in use: $(Get-KitActiveTemplate)"
Write-KitLog ''
Write-KitLog "Bootstrap (admin) credentials: $(Join-Path $KitDir '.runtime/bootstrap-credentials.json')"
Write-KitLog ('This is an administrative credential for local testing only -- it is not ' +
    'representative of a production integration client.')
Write-KitLog ''
Write-KitLog 'Next steps:'
Write-KitLog '  - Create a scoped credential: ./new-credential.ps1 -Shape sis -Name <your-name>'
Write-KitLog '  - Run the smoke test:         ./smoke-test.ps1'
