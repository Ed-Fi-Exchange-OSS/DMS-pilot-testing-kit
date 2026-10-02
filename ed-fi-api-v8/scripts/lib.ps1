# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
Shared PowerShell helpers for the Task 12 lifecycle scripts (start.ps1, stop.ps1, reset.ps1,
bootstrap.ps1), available to any later host wrapper that wants them. Dot-source it, don't invoke it:
    . (Join-Path $PSScriptRoot 'scripts/lib.ps1')
This mirrors scripts/lib.sh function-for-function so the two shells produce the same observable
behavior (FR-LIFE-3). No cmdlet or syntax here is PowerShell-7-only, so it also runs on Windows
PowerShell 5.1; only ssl/generate-certificate.ps1's #Requires 7 (for its .NET certificate fallback
path) is a harder requirement, and only when OpenSSL isn't on PATH.

Public API (everything else here is a private helper, prefixed with an underscore):
    $KitDir                              absolute path of ed-fi-api-v8/, computed from this file's
                                          own location -- independent of the caller's working
                                          directory
    Write-KitLog / Write-KitWarn         plain / "WARNING: " prefixed, to the console
    Stop-KitWithError                    "ERROR: " prefixed to stderr, then exit 1
    Assert-KitDockerRunning              docker on PATH and the daemon reachable, else fatal
    Assert-KitComposeAvailable           Compose v2 available, else fatal
    Invoke-KitCompose <args...>          runs `docker compose <args...>` from $KitDir, streaming
                                          output to the console; sets $LASTEXITCODE
    Get-KitComposeOutput <args...>       same, but captures and returns stdout instead of streaming
                                          it (for `ps`/`exec` queries the caller needs to parse)
    Get-KitEnvValue -Name X [-Default Y] read a value from .env (or the default if unset/absent)
    Test-KitEnvHasKey -Name X            true if X= appears in .env
    Set-KitEnvValue -Name X -Value Y     replace or append X=Y in .env
    New-KitSecret -Length N [-Pool full|safe]
                                          a local secret of exactly N characters with at least one
                                          lowercase, one uppercase, one digit, and one special
                                          character. "safe" (default "full") drops ';' from the
                                          special-character pool -- see the comment below.
    New-KitBase64Key [-Bytes N]          base64 of N (default 32) cryptographically random bytes
    Initialize-KitEnvFile                create .env from .env.example with generated secrets if it
                                          doesn't exist; otherwise warn (by name) about any variable
                                          in .env.example that .env is missing. Never modifies an
                                          existing .env value, and never prints a secret value.
    Initialize-KitCertificates           generate ssl/server.{crt,key} if either is missing
    Initialize-KitDirectories            create .runtime/ and ${LOG_DIR:-./logs}/nginx
    Get-KitComposeFailures               one object (Service, Reason) per exited(non-zero)/unhealthy
                                          container, from `docker compose ps -a --format json`
    Show-KitFailureLogs -Service X       last 20 lines of the service's logs, plus the full-log
                                          command
    Show-KitUrls                         the kit's participant-facing URLs, from .env
    Get-KitActiveTemplate                the template marker row from the database, falling back to
                                          .env's DATABASE_TEMPLATE if the query fails or returns
                                          nothing
    Test-KitStackRunning [-Service X]    true if X (default "dms") is running
#>

Set-StrictMode -Version Latest

$script:KitDir = Split-Path -Parent $PSScriptRoot

function Write-KitLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Message)
    Write-Host $Message
}

function Write-KitWarn {
    param([Parameter(Mandatory)][string] $Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}

function Stop-KitWithError {
    param([Parameter(Mandatory)][string] $Message)
    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

# ------------------------------------------------------------------------------------------------
# Docker / Compose
# ------------------------------------------------------------------------------------------------

function Assert-KitDockerRunning {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-KitWithError ('Docker was not found on PATH. Install Docker Desktop: ' +
            'https://docs.docker.com/get-docker/')
    }
    & docker info *>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-KitWithError ('Docker is installed but not responding (docker info failed). ' +
            'Start Docker Desktop and try again.')
    }
}

function Assert-KitComposeAvailable {
    & docker compose version *>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-KitWithError ('Docker Compose v2 was not found (docker compose version failed). ' +
            'Update Docker Desktop, or install the compose plugin: ' +
            'https://docs.docker.com/compose/install/')
    }
}

# Invoke-KitCompose <args...> -- always from $KitDir, per compose.yml's header warning: the
# included files read ./.env, so this kit never passes --env-file, and every invocation must run
# from ed-fi-api-v8/. Streams output live (for `up`, `down`, `stop`, `run`). $LASTEXITCODE is a
# global automatic variable that PowerShell sets after any native command regardless of the calling
# function's scope, so it is already correct for the caller to check right after this returns --
# neither this function nor its `finally` block needs to (or should) reassign it.
# Deliberately a *simple* function (no param block): a param block with
# [Parameter(ValueFromRemainingArguments)] makes PowerShell treat this as an advanced function,
# which adds the common parameters (-Verbose, -Debug, ...) to its binding -- and then a bare `-v`
# (as in `docker compose down -v`) gets silently swallowed as an abbreviation of -Verbose instead of
# reaching docker. The automatic $args variable has no such collision.
function Invoke-KitCompose {
    Push-Location $script:KitDir
    try {
        & docker compose @args
    }
    finally {
        Pop-Location
    }
}

# Get-KitComposeOutput <args...> -- same, but captures stdout (stderr discarded) and returns it as
# a string array, for callers that need to parse the result (`ps`, `exec ... psql`).
# Simple function for the same reason as Invoke-KitCompose above.
function Get-KitComposeOutput {
    Push-Location $script:KitDir
    try {
        & docker compose @args 2>$null
    }
    finally {
        Pop-Location
    }
}

# ------------------------------------------------------------------------------------------------
# .env access
# ------------------------------------------------------------------------------------------------

function Get-KitEnvFile { Join-Path $script:KitDir '.env' }

function Test-KitEnvHasKey {
    param([Parameter(Mandatory)][string] $Name)
    $file = Get-KitEnvFile
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    $pattern = '^' + [regex]::Escape($Name) + '='
    return [bool](Select-String -LiteralPath $file -Pattern $pattern -Quiet)
}

function Get-KitEnvValue {
    param([Parameter(Mandatory)][string] $Name, [string] $Default = '')
    $file = Get-KitEnvFile
    if (-not (Test-Path -LiteralPath $file)) { return $Default }
    $pattern = '^' + [regex]::Escape($Name) + '='
    $matches = Select-String -LiteralPath $file -Pattern $pattern
    if (-not $matches) { return $Default }
    $line = ($matches | Select-Object -Last 1).Line
    return $line.Substring($Name.Length + 1)
}

# Set-KitEnvValue -Name X -Value Y -- replaces an existing X= line in place (preserving every other
# line untouched, including any '=' inside other values) or appends X=Y if absent. Requires .env to
# already exist.
function Set-KitEnvValue {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Value)
    $file = Get-KitEnvFile
    if (-not (Test-Path -LiteralPath $file)) {
        Stop-KitWithError "$file does not exist"
    }
    $pattern = '^' + [regex]::Escape($Name) + '='
    $lines = @(Get-Content -LiteralPath $file)
    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $found = $true
            "$Name=$Value"
        }
        else {
            $line
        }
    }
    if (-not $found) {
        $newLines = @($newLines) + "$Name=$Value"
    }
    Set-Content -LiteralPath $file -Value $newLines
}

# ------------------------------------------------------------------------------------------------
# Secret generation. LOCAL DEVELOPMENT ONLY -- see .env.example's header. Every generated value has
# at least one lowercase letter, one uppercase letter, one digit, and one special character, which
# satisfies both the 32-128 character client-secret rule and the exactly-32-character
# CMS_DATABASE_ENCRYPTION_KEY rule (call with the exact length wanted). Uses .NET's RNG (no host
# .NET SDK is required -- RandomNumberGenerator ships in the PowerShell runtime itself).
# ------------------------------------------------------------------------------------------------

$script:KitLower = 'abcdefghijklmnopqrstuvwxyz'
$script:KitUpper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
$script:KitDigit = '0123456789'
# No '$': Compose interpolates it in .env values, which would corrupt the secret.
# No '&' or '=': CMS_ADMIN_CLIENT_SECRET (and the other CMS_*_CLIENT_SECRET values generated from
# this pool) is embedded unescaped into application/x-www-form-urlencoded request bodies built by
# naive string concatenation -- see http/claimset-test.http's
# "grant_type=client_credentials&client_id=...&client_secret={{CMS_ADMIN_CLIENT_SECRET}}&scope=..."
# line, where the VS Code REST Client extension substitutes the placeholder as literal text without
# urlencoding it. A literal '&' in the secret would be read as a field separator, and a literal '='
# would make everything after it in that chunk part of the wrong field, corrupting the request.
$script:KitSpecialFull = '!@#%^*()-_+[]{}:;,.?'
# Same set without ';'. POSTGRES_PASSWORD is embedded, unescaped, into semicolon-delimited
# ADO.NET/Npgsql-style connection strings elsewhere in the kit (compose.core.yml
# DatabaseSettings__DatabaseConnection and DATABASE_CONNECTION_STRING_ADMIN, and the connection
# string init/datastore.sh registers with CMS); a literal ';' in the password would truncate or
# corrupt those. PGADMIN_DEFAULT_PASSWORD and CMS_DATABASE_ENCRYPTION_KEY use the same safe pool
# out of caution, even though neither is known to need it today.
$script:KitSpecialSafe = '!@#%^*()-_+[]{}:,.?'

function Get-KitRandomChars {
    param([Parameter(Mandatory)][string] $Pool, [Parameter(Mandatory)][int] $Count)
    if ($Count -le 0) { return '' }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = [byte[]]::new($Count)
        $rng.GetBytes($bytes)
        $chars = foreach ($b in $bytes) { $Pool[$b % $Pool.Length] }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

function Invoke-KitShuffleString {
    param([Parameter(Mandatory)][string] $Value)
    $chars = $Value.ToCharArray()
    $n = $chars.Length
    if ($n -le 1) { return $Value }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($i = $n - 1; $i -gt 0; $i--) {
            $buf = [byte[]]::new(4)
            $rng.GetBytes($buf)
            $j = [BitConverter]::ToUInt32($buf, 0) % ($i + 1)
            $tmp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

# Swaps the first and last character if $Value starts with '-'. Nothing in this kit passes a
# generated secret as a bare CLI argument today (every call site embeds it in a larger string:
# KEY=VALUE, "key:secret", "client_secret=value"), but a value that could be mistaken for a flag by
# some future consumer is a cheap footgun to remove at generation time.
function Remove-KitLeadingDash {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value.Length -gt 1 -and $Value[0] -eq '-') {
        $chars = $Value.ToCharArray()
        $last = $chars.Length - 1
        $first = $chars[0]
        $chars[0] = $chars[$last]
        $chars[$last] = $first
        return -join $chars
    }
    return $Value
}

function New-KitSecret {
    param(
        [Parameter(Mandatory)][int] $Length,
        [ValidateSet('full', 'safe')][string] $Pool = 'full'
    )
    $special = if ($Pool -eq 'safe') { $script:KitSpecialSafe } else { $script:KitSpecialFull }
    $all = $script:KitLower + $script:KitUpper + $script:KitDigit + $special
    $guaranteed = (Get-KitRandomChars $script:KitLower 1) + (Get-KitRandomChars $script:KitUpper 1) +
    (Get-KitRandomChars $script:KitDigit 1) + (Get-KitRandomChars $special 1)
    $rest = Get-KitRandomChars $all ($Length - 4)
    return Remove-KitLeadingDash (Invoke-KitShuffleString ($guaranteed + $rest))
}

function New-KitBase64Key {
    param([int] $Bytes = 32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buf = [byte[]]::new($Bytes)
        $rng.GetBytes($buf)
        return [Convert]::ToBase64String($buf)
    }
    finally {
        $rng.Dispose()
    }
}

# ------------------------------------------------------------------------------------------------
# start.ps1 building blocks (reusable by any future wrapper)
# ------------------------------------------------------------------------------------------------

function Initialize-KitEnvFile {
    $envFile = Get-KitEnvFile
    $exampleFile = Join-Path $script:KitDir '.env.example'
    if (-not (Test-Path -LiteralPath $exampleFile)) {
        Stop-KitWithError ".env.example not found in $script:KitDir"
    }

    if (-not (Test-Path -LiteralPath $envFile)) {
        Write-KitLog 'No .env found. Creating one from .env.example with freshly generated local secrets.'
        Copy-Item -LiteralPath $exampleFile -Destination $envFile

        Set-KitEnvValue -Name 'POSTGRES_PASSWORD' -Value (New-KitSecret -Length 32 -Pool safe)
        Set-KitEnvValue -Name 'CMS_SERVICE_CLIENT_SECRET' -Value (New-KitSecret -Length 48 -Pool full)
        Set-KitEnvValue -Name 'CMS_READONLY_CLIENT_SECRET' -Value (New-KitSecret -Length 48 -Pool full)
        Set-KitEnvValue -Name 'CMS_ADMIN_CLIENT_SECRET' -Value (New-KitSecret -Length 48 -Pool full)
        Set-KitEnvValue -Name 'CMS_DATABASE_ENCRYPTION_KEY' -Value (New-KitSecret -Length 32 -Pool safe)
        Set-KitEnvValue -Name 'CMS_IDENTITY_ENCRYPTION_KEY' -Value (New-KitBase64Key -Bytes 32)
        Set-KitEnvValue -Name 'PGADMIN_DEFAULT_PASSWORD' -Value (New-KitSecret -Length 32 -Pool safe)

        Write-KitLog 'Generated local secrets for POSTGRES_PASSWORD, CMS_SERVICE_CLIENT_SECRET,'
        Write-KitLog 'CMS_READONLY_CLIENT_SECRET, CMS_ADMIN_CLIENT_SECRET, CMS_DATABASE_ENCRYPTION_KEY,'
        Write-KitLog 'CMS_IDENTITY_ENCRYPTION_KEY, and PGADMIN_DEFAULT_PASSWORD.'
        Write-KitLog "Values are never printed; see $envFile if you need one of them."
        return
    }

    $missing = @()
    foreach ($line in Get-Content -LiteralPath $exampleFile) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        $key = ($line -split '=', 2)[0]
        if ([string]::IsNullOrEmpty($key)) { continue }
        if (-not (Test-KitEnvHasKey -Name $key)) { $missing += $key }
    }

    if ($missing.Count -gt 0) {
        Write-KitWarn (".env exists but is missing variables present in .env.example: " +
            ($missing -join ', '))
        Write-KitWarn "Add them to $envFile (existing values in .env are never changed automatically)."
        Write-KitWarn 'Defaults from .env.example:'
        foreach ($key in $missing) {
            $pattern = '^' + [regex]::Escape($key) + '='
            $defaultLine = (Select-String -LiteralPath $exampleFile -Pattern $pattern |
                Select-Object -First 1).Line
            Write-KitWarn "  $defaultLine"
        }
    }
}

function Initialize-KitCertificates {
    $crt = Join-Path $script:KitDir 'ssl/server.crt'
    $key = Join-Path $script:KitDir 'ssl/server.key'
    if (-not (Test-Path -LiteralPath $crt) -or -not (Test-Path -LiteralPath $key)) {
        Write-KitLog 'TLS certificate missing; generating a local self-signed certificate.'
        & (Join-Path $script:KitDir 'ssl/generate-certificate.ps1')
        if ($LASTEXITCODE -ne 0) {
            Stop-KitWithError 'certificate generation failed; see ssl/generate-certificate.ps1 -Help'
        }
    }
}

function Initialize-KitDirectories {
    $logDir = Get-KitEnvValue -Name 'LOG_DIR' -Default './logs'
    if (-not [System.IO.Path]::IsPathRooted($logDir)) {
        $logDir = Join-Path $script:KitDir $logDir
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $script:KitDir '.runtime') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $logDir 'nginx') | Out-Null
}

# ------------------------------------------------------------------------------------------------
# Failure diagnosis, used by start.ps1 (FR-LIFE-9)
# ------------------------------------------------------------------------------------------------

# `docker compose ps --format json` has printed either one JSON object per line, or a single JSON
# array, depending on the Compose version. ConvertFrom-Json handles a single well-formed document;
# for line-delimited objects (which aren't one valid document), each line is converted on its own.
function Get-KitComposeContainers {
    $raw = Get-KitComposeOutput ps -a --format json
    $text = ($raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    try {
        return @($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $items = foreach ($line in $raw) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $line | ConvertFrom-Json
            }
        }
        return @($items)
    }
}

# Get-KitComposeFailures -- one object (Service, Reason) per container that is unhealthy, or exited
# with a non-zero code (covers both a failed one-shot init step and a long-running service that
# died). Returns an empty array if every container looks fine.
function Get-KitComposeFailures {
    $containers = Get-KitComposeContainers
    $failures = foreach ($c in $containers) {
        $health = if ($c.PSObject.Properties['Health']) { $c.Health } else { '' }
        $exitCode = if ($c.PSObject.Properties['ExitCode']) { $c.ExitCode } else { 0 }
        if ($health -eq 'unhealthy') {
            [PSCustomObject]@{ Service = $c.Service; Reason = 'unhealthy' }
        }
        elseif ($c.State -eq 'exited' -and $exitCode -ne 0) {
            [PSCustomObject]@{ Service = $c.Service; Reason = "exited with code $exitCode" }
        }
    }
    return @($failures)
}

function Show-KitFailureLogs {
    param([Parameter(Mandatory)][string] $Service)
    Write-KitLog ''
    Write-KitLog "----- last 20 lines of '$Service' -----"
    $logLines = Get-KitComposeOutput logs --no-color --tail=20 $Service
    foreach ($line in $logLines) { Write-KitLog "  $line" }
    Write-KitLog "Full logs: (cd `"$script:KitDir`"; docker compose logs $Service)"
}

# ------------------------------------------------------------------------------------------------
# Success output
# ------------------------------------------------------------------------------------------------

function Show-KitUrls {
    $origin = Get-KitEnvValue -Name 'PUBLIC_ORIGIN' -Default 'https://localhost'
    $dmsBase = Get-KitEnvValue -Name 'DMS_PATH_BASE' -Default 'api'
    $cmsBase = Get-KitEnvValue -Name 'CMS_PATH_BASE' -Default 'config'
    Write-KitLog "  API / Discovery:  $origin/$dmsBase"
    Write-KitLog "  Token endpoint:   $origin/$dmsBase/oauth/token"
    Write-KitLog "  CMS config:       $origin/$cmsBase"
    Write-KitLog "  Swagger UI:       $origin/swagger"
    Write-KitLog "  PGAdmin:          $origin/pgadmin"
}

# Get-KitActiveTemplate -- the most recent kit.initialization.template row, read live from the
# database so a stale .env DATABASE_TEMPLATE can't misreport what's actually loaded; falls back to
# .env if the query fails (for example, the database isn't reachable) or returns no row yet.
function Get-KitActiveTemplate {
    $db = Get-KitEnvValue -Name 'POSTGRES_DB_NAME' -Default 'edfi_datamanagementservice'
    $sql = 'SELECT template FROM kit.initialization ORDER BY completed_at DESC LIMIT 1'
    $result = Get-KitComposeOutput exec -T db psql -U postgres -d $db -tAc $sql
    $value = (($result -join '') -replace '[\r\n\s]', '')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = Get-KitEnvValue -Name 'DATABASE_TEMPLATE' -Default 'minimal'
    }
    return $value
}

# Test-KitStackRunning [-Service X] -- true if X (default "dms") is currently running. Used to fail
# fast with "run start first" instead of letting `docker compose run` bring up dependencies on its
# own (bootstrap.ps1, and later new-credential.ps1 / smoke-test.ps1).
function Test-KitStackRunning {
    param([string] $Service = 'dms')
    $running = @(Get-KitComposeOutput ps --status running --services)
    return $running -contains $Service
}
