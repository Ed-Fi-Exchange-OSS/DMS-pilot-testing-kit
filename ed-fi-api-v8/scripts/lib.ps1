# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

<#
Shared PowerShell helpers for the Task 12 lifecycle scripts (start.ps1, stop.ps1, reset.ps1,
bootstrap.ps1), available to any later host wrapper that wants them. Dot-source it, don't invoke it:
    . (Join-Path $PSScriptRoot 'scripts/lib.ps1')
This mirrors scripts/lib.sh function-for-function so the two shells produce the same observable
behavior (FR-LIFE-3). The kit requires PowerShell 7 (pwsh); Windows PowerShell 5.1 is not
supported. Each entry-point script declares #Requires -Version 7, so this file doesn't repeat it.

Public API (everything else here is a private helper, prefixed with an underscore):
    $KitDir                              absolute path of ed-fi-api-v8/, computed from this file's
                                          own location -- independent of the caller's working
                                          directory
    Write-KitLog / Write-KitWarn         plain / "WARNING: " prefixed, to the console
    Stop-KitWithError                    "ERROR: " prefixed to stderr, then exit 1
    Assert-KitDockerRunning              docker on PATH and the daemon reachable, else fatal
    Assert-KitComposeAvailable           Compose 2.20+ available, else fatal
    Invoke-KitCompose <args...>          runs `docker compose <args...>` from $KitDir, streaming
                                          output to the console; sets $LASTEXITCODE
    Get-KitComposeOutput <args...>       same, but captures and returns stdout instead of streaming
                                          it (for `ps`/`exec` queries the caller needs to parse)
    Invoke-KitComposeTee <args...>       same as Invoke-KitCompose (streams stdout+stderr live, sets
                                          $LASTEXITCODE), and also returns the output lines
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
                                          Refuses (error) to generate new secrets if .env is missing
                                          but this kit's Docker volumes still exist.
    Assert-KitPublicOrigin               error unless PUBLIC_ORIGIN's port matches HTTPS_PORT
    Initialize-KitCertificates           generate ssl/server.{crt,key} if either is missing
    Initialize-KitDirectories            create .runtime/ and ${LOG_DIR:-./logs}/nginx
    Get-KitComposeFailures [-UpOutput L] one object (Service, Reason) per failing service: those
                                          named in Compose's `up --wait` errors in the lines L
                                          first, then any unhealthy, exited(non-zero),
                                          never-started, or suspect one-shot init- container from
                                          `docker compose ps -a`
    Show-KitFailureLogs -Service X       last 20 lines of the service's logs, plus the full-log
                                          command
    Show-KitUpFailure -UpOutput L        the full startup-failure report: Compose's own error
                                          lines, each failing service with its recent logs, and the
                                          inspect commands
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Only writes to stderr and exits; the Stop- verb triggers this rule but no state is mutated.')]
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

# compose.yml uses top-level `include`, which needs Compose 2.20 or later.
function Assert-KitComposeAvailable {
    $version = & docker compose version --short 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-KitWithError ('Docker Compose v2 was not found (docker compose version failed). ' +
            'Update Docker Desktop, or install the compose plugin: ' +
            'https://docs.docker.com/compose/install/')
    }
    # --short prints e.g. 2.29.7, v2.20.0, or 2.40.3-desktop.1.
    $version = "$version".Trim()
    if ($version -notmatch '^v?(\d+)\.(\d+)') {
        Write-KitWarn ("Could not read the Docker Compose version ('$version'); " +
            'this kit needs 2.20 or later.')
        return
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 20)) {
        Stop-KitWithError ("Docker Compose $version is too old; this kit needs 2.20 or later. " +
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
    # Defensive: 2>$null can still turn each stderr line into an ErrorRecord first, which must not
    # become terminating under a caller's 'Stop' (see Invoke-KitComposeTee below).
    $ErrorActionPreference = 'Continue'
    Push-Location $script:KitDir
    try {
        & docker compose @args 2>$null
    }
    finally {
        Pop-Location
    }
}

# Invoke-KitComposeTee <args...> -- Invoke-KitCompose, with stdout and stderr (where Compose writes
# its progress and errors) both shown live and also returned as string lines, so a failed
# `up --wait` can be diagnosed from Compose's own messages afterwards. $LASTEXITCODE is Compose's,
# as for Invoke-KitCompose. Since the output is now a pipe rather than a terminal, Compose shows its
# plain (line-by-line) progress. Simple function for the same reason as Invoke-KitCompose above.
function Invoke-KitComposeTee {
    # With 2>&1, each stderr line arrives as an ErrorRecord. PowerShell 7.2 and later don't apply a
    # caller's $ErrorActionPreference = 'Stop' to native stderr, but older hosts made it terminating.
    # Compose writes all of its progress to stderr, so relax that defensively for this function's
    # scope only.
    $ErrorActionPreference = 'Continue'
    Push-Location $script:KitDir
    try {
        & docker compose @args 2>&1 | ForEach-Object {
            $line = "$_"
            Write-KitLog $line
            $line
        }
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
    $envLines = Select-String -LiteralPath $file -Pattern $pattern
    if (-not $envLines) { return $Default }
    $line = ($envLines | Select-Object -Last 1).Line
    return $line.Substring($Name.Length + 1)
}

# Set-KitEnvValue -Name X -Value Y -- replaces an existing X= line in place (preserving every other
# line untouched, including any '=' inside other values) or appends X=Y if absent. Requires .env to
# already exist.
function Set-KitEnvValue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Always called unconditionally by the kit''s own non-interactive scripts, never interactively, so there is no caller that would want to preview or skip the .env write with -WhatIf/-Confirm.')]
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
# No '+' or '%' for the same reason: form decoding turns a literal '+' into a space and reads '%XX'
# as a percent-escape, so either one would silently change the secret the server compares against.
$script:KitSpecialFull = '!@#^*()-_[]{}:;,.?'
# Same set without ';'. POSTGRES_PASSWORD is embedded, unescaped, into semicolon-delimited
# ADO.NET/Npgsql-style connection strings elsewhere in the kit (compose.core.yml
# DatabaseSettings__DatabaseConnection and DATABASE_CONNECTION_STRING_ADMIN, and the connection
# string init/datastore.sh registers with CMS); a literal ';' in the password would truncate or
# corrupt those. PGADMIN_DEFAULT_PASSWORD and CMS_DATABASE_ENCRYPTION_KEY use the same safe pool
# out of caution, even though neither is known to need it today.
$script:KitSpecialSafe = '!@#^*()-_[]{}:,.?'

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string manipulation that returns a possibly-rearranged string; the Remove- verb triggers this rule but nothing is mutated.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory random-string generator with no side effects; the New- verb triggers this rule but nothing external changes.')]
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory generator of random bytes encoded as base64, with no side effects; same false positive as New-KitSecret.')]
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

# Get-KitExistingVolumes -- names of this kit's Docker volumes, found by the Compose project label
# (the same set `docker compose down -v`, which reset.ps1 runs, would delete). The project name is
# KIT_PROJECT_NAME from the environment, else compose.yml's default; with .env missing there is
# nowhere else to read it from.
function Get-KitExistingVolumes {
    $project = if ($env:KIT_PROJECT_NAME) { $env:KIT_PROJECT_NAME } else { 'edfi-pilot' }
    $names = & docker volume ls -q --filter "label=com.docker.compose.project=$project" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($names | Where-Object { $_ })
}

function Initialize-KitEnvFile {
    $envFile = Get-KitEnvFile
    $exampleFile = Join-Path $script:KitDir '.env.example'
    if (-not (Test-Path -LiteralPath $exampleFile)) {
        Stop-KitWithError ".env.example not found in $script:KitDir"
    }

    if (-not (Test-Path -LiteralPath $envFile)) {
        # New secrets would not match an existing database or the CMS state encrypted with the old
        # keys, so refuse rather than generate them. Nothing is deleted here.
        $volumes = @(Get-KitExistingVolumes)
        if ($volumes.Count -gt 0) {
            Stop-KitWithError (".env is missing, but this kit's Docker volumes already exist: " +
                ($volumes -join ', ') + '. Freshly generated secrets would not match the existing ' +
                "database and encrypted CMS state. Restore the original .env into $script:KitDir, " +
                'or run ./reset.ps1 to DELETE that data and start fresh.')
        }
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

# Assert-KitPublicOrigin -- PUBLIC_ORIGIN must carry the same port as HTTPS_PORT (none, or :443, for
# 443). Otherwise the printed URLs, the saved credential files, and the CORS origins all point at
# the wrong port.
function Assert-KitPublicOrigin {
    $port = Get-KitEnvValue -Name 'HTTPS_PORT' -Default '443'
    $origin = Get-KitEnvValue -Name 'PUBLIC_ORIGIN' -Default 'https://localhost'
    $trimmed = $origin.TrimEnd('/')
    $base = $trimmed
    $effective = '443'
    if ($trimmed -match '^(.*):([0-9]+)$') {
        $base = $Matches[1]
        $effective = $Matches[2]
    }
    if ($effective -eq $port) { return }
    $expected = if ($port -eq '443') { $base } else { "${base}:$port" }
    Stop-KitWithError ("HTTPS_PORT is $port but PUBLIC_ORIGIN is $origin, which implies port " +
        "$effective. Set PUBLIC_ORIGIN=$expected in $(Get-KitEnvFile) (or change HTTPS_PORT to match).")
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
# The `ForEach-Object { $_ }` defensively unrolls the array shape, so a JSON array always yields one
# object per element whatever the host's ConvertFrom-Json does with it.
function Get-KitComposeContainers {
    $raw = Get-KitComposeOutput ps -a --format json
    $text = ($raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    try {
        return @($text | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ })
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

# Get-KitJsonProperty -Object O -Name X -- O.X as a string, or '' if O has no X (Set-StrictMode
# makes reading a missing property an error).
function Get-KitJsonProperty {
    param($Object, [string] $Name)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return "$($Object.$Name)"
    }
    return ''
}

# The failure messages `docker compose up --wait` itself prints, in Compose's wording:
#   container <name> has no healthcheck configured
#   container <name> exited (<code>)
#   container <name> is unhealthy
#   service "<service>" didn't complete successfully: exit <code>
# often behind a prefix such as `dependency failed to start: `. Matched case-insensitively (-match's
# default), and loosely enough to survive small wording changes between Compose versions.
$script:KitWaitErrorPattern = 'container [^ ]+ (has no healthcheck configured|exited \(-?[0-9]+\)' +
'|is unhealthy)|service "?[^" ]+"? didn.?t complete successfully'

# ConvertTo-KitPlainLines -Lines L -- L without carriage returns or ANSI color/cursor sequences.
function ConvertTo-KitPlainLines {
    param([string[]] $Lines = @())
    foreach ($line in $Lines) {
        ("$line" -replace "`r", '') -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
    }
}

# Get-KitComposeWaitErrors -Lines L -- the distinct --wait error lines in captured `up` output,
# trimmed, in the order Compose printed them.
function Get-KitComposeWaitErrors {
    param([string[]] $Lines = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in (ConvertTo-KitPlainLines -Lines $Lines)) {
        if ($line -match $script:KitWaitErrorPattern) {
            $trimmed = $line.Trim()
            if ($seen.Add($trimmed)) { $trimmed }
        }
    }
}

# Get-KitLastOutputLines -Lines L -Count N -- the last N non-blank lines of L, trimmed.
function Get-KitLastOutputLines {
    param([string[]] $Lines = @(), [int] $Count)
    $nonBlank = @(ConvertTo-KitPlainLines -Lines $Lines |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() })
    if ($nonBlank.Count -eq 0) { return }
    $nonBlank | Select-Object -Last $Count
}

# Get-KitCompletionDependencies -- the services some other service depends on with
# `condition: service_completed_successfully`, from `docker compose config --format json` (which is
# held in memory only: it contains the interpolated .env secrets). Returns $null if the
# configuration couldn't be read, so the caller can tell "none" (an empty array) from "unknown".
function Get-KitCompletionDependencies {
    $raw = Get-KitComposeOutput config --format json
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($raw -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        $config = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
    $services = if ($config.PSObject.Properties['services']) { $config.services } else { $null }
    $deps = @()
    if ($null -ne $services) {
        foreach ($service in $services.PSObject.Properties) {
            if (-not $service.Value.PSObject.Properties['depends_on']) { continue }
            foreach ($dep in $service.Value.depends_on.PSObject.Properties) {
                $condition = Get-KitJsonProperty $dep.Value 'condition'
                if ($condition -eq 'service_completed_successfully') { $deps += $dep.Name }
            }
        }
    }
    # The leading comma keeps an empty result an (empty) array instead of collapsing to $null.
    return , @($deps | Sort-Object -Unique)
}

# Get-KitContainerProblem -- the reason a container looks like a startup failure, or '' if it looks
# fine. -Named: Compose's own --wait error named it. -CompletionDependencies:
# Get-KitCompletionDependencies' result ($null if unknown).
function Get-KitContainerProblem {
    param($Container, [bool] $Named, $CompletionDependencies)
    $service = Get-KitJsonProperty $Container 'Service'
    $state = Get-KitJsonProperty $Container 'State'
    $health = Get-KitJsonProperty $Container 'Health'
    $exitCode = Get-KitJsonProperty $Container 'ExitCode'
    $depsKnown = $null -ne $CompletionDependencies
    if ($health -eq 'unhealthy') {
        return 'unhealthy'
    }
    if ($state -eq 'exited' -and $exitCode -ne '' -and $exitCode -ne '0') {
        return "exited with code $exitCode"
    }
    if ($state -eq 'created') {
        return 'never started (a dependency likely failed or was not satisfied)'
    }
    if ($service -like 'init-*' -and ($state -eq 'exited' -or $state -eq 'running') -and
        (($depsKnown -and $CompletionDependencies -notcontains $service) -or
        (-not $depsKnown -and $Named))) {
        # A one-shot init step that finished (or is still going) is only a problem if `--wait` was
        # waiting for it to be *healthy* -- which is what Compose does for any service that nothing
        # else waits on with service_completed_successfully.
        $what = if ($state -eq 'exited') { 'exited with code 0' } else { 'still running' }
        return ("$what; Compose --wait may have checked this one-shot service as a long-running " +
            'one, because no other service depends on it with ' +
            'condition: service_completed_successfully')
    }
    if ($Named) {
        return "named in Compose's error above (state: $state)"
    }
    return ''
}

# Get-KitComposeFailures [-UpOutput L] -- one object (Service, Reason) per failing service, each
# service at most once: first the services Compose's own --wait errors in the captured `up` output L
# name (container names map back to services through `docker compose ps -a`, never by trimming the
# name), then any other container that is unhealthy, exited non-zero, never started, or is a
# one-shot init- service --wait likely treated as long-running. Returns an empty array if nothing
# can be identified.
function Get-KitComposeFailures {
    param([string[]] $UpOutput = @())
    $namedContainers = @()
    $namedServices = @()
    foreach ($line in (Get-KitComposeWaitErrors -Lines $UpOutput)) {
        if ($line -match 'container /?([^ ]+) (has no|exited|is unhealthy)') {
            $namedContainers += $Matches[1]
        }
        if ($line -match 'service "?([^" ]+)"? didn.?t') {
            $namedServices += $Matches[1]
        }
    }
    $containers = @(Get-KitComposeContainers)
    $deps = Get-KitCompletionDependencies

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    # Two passes over the same containers, so the services Compose named are reported first.
    foreach ($pass in 'named', 'other') {
        foreach ($c in $containers) {
            $service = Get-KitJsonProperty $c 'Service'
            if ([string]::IsNullOrEmpty($service)) { continue }
            $named = ($namedContainers -contains (Get-KitJsonProperty $c 'Name')) -or
            ($namedServices -contains $service)
            if (($pass -eq 'named') -ne $named) { continue }
            if ($seen.Contains($service)) { continue }
            $reason = Get-KitContainerProblem -Container $c -Named $named `
                -CompletionDependencies $deps
            if ([string]::IsNullOrEmpty($reason)) { continue }
            $failures.Add([PSCustomObject]@{ Service = $service; Reason = $reason })
            [void]$seen.Add($service)
        }
    }

    # A service Compose named by service name that `ps -a` doesn't list at all.
    foreach ($service in $namedServices) {
        if ($seen.Add($service)) {
            $failures.Add([PSCustomObject]@{
                    Service = $service
                    Reason  = "named in Compose's error above (no container found)"
                })
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

# Show-KitUpFailure -UpOutput L -- what start.ps1 prints after `up --wait` fails, given that
# command's captured output L: Compose's own --wait error lines (or, if none is recognized, its last
# few output lines), then each failing service with its recent logs, then the inspect commands.
function Show-KitUpFailure {
    param([string[]] $UpOutput = @())
    Write-KitLog ''
    Write-KitLog 'Startup did not complete.'
    $errors = @(Get-KitComposeWaitErrors -Lines $UpOutput)
    if ($errors.Count -gt 0) {
        Write-KitLog 'Compose reported:'
        foreach ($line in $errors) { Write-KitLog "  $line" }
    }
    else {
        $last = @(Get-KitLastOutputLines -Lines $UpOutput -Count 5)
        if ($last.Count -gt 0) {
            Write-KitLog ('Compose did not report a recognized --wait error. ' +
                'Its last output lines were:')
            foreach ($line in $last) { Write-KitLog "  $line" }
        }
        else {
            Write-KitLog 'Compose printed no output.'
        }
    }
    Write-KitLog ''
    Write-KitLog 'Checking service status...'
    $failures = @(Get-KitComposeFailures -UpOutput $UpOutput)
    if ($failures.Count -gt 0) {
        foreach ($f in $failures) {
            Write-KitLog "FAILED: $($f.Service) ($($f.Reason))"
            Show-KitFailureLogs -Service $f.Service
        }
    }
    else {
        Write-KitLog ("Could not identify a failing service from Compose's output or its service " +
            'status.')
    }
    Write-KitLog ''
    Write-KitLog 'Inspect further with:'
    Write-KitLog "  cd `"$script:KitDir`"; docker compose ps -a"
    Write-KitLog "  cd `"$script:KitDir`"; docker compose logs"
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
