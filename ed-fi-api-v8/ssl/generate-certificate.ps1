# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

#Requires -Version 7

using namespace System.Security.Cryptography
using namespace System.Security.Cryptography.X509Certificates

<#
.SYNOPSIS
    Creates a self-signed TLS certificate for the kit's NGINX ingress.

.DESCRIPTION
    Writes server.crt and server.key (PEM) next to this script: RSA 2048, valid 365 days,
    SANs DNS:localhost, DNS:nginx, IP:127.0.0.1. For local development only.
    Uses openssl when it is on PATH; otherwise uses .NET's CertificateRequest API, so no
    bash or OpenSSL install is needed on Windows. generate-certificate.sh does the same
    thing with the same options.

.PARAMETER Force
    Replace existing server.crt and server.key.

.EXAMPLE
    ./ssl/generate-certificate.ps1

.EXAMPLE
    ./ssl/generate-certificate.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Help) {
    Get-Help -Full $PSCommandPath
    exit 0
}

$sslDir = $PSScriptRoot
$crt = Join-Path $sslDir 'server.crt'
$key = Join-Path $sslDir 'server.key'
$days = 365

function Stop-WithError {
    # Attribute placement note: a PowerShell function-level attribute can only precede an explicit
    # param() block, not an inline parenthesized parameter list, so the single $Message parameter is
    # declared here instead of inline -- purely to give the suppression attribute somewhere valid to
    # attach; behavior is unchanged.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Only writes to stderr and exits; the Stop- verb triggers this rule but no state is mutated.')]
    param([string] $Message)
    [Console]::Error.WriteLine("ERROR: $Message")
    exit 1
}

if (-not $Force -and ((Test-Path $crt) -or (Test-Path $key))) {
    Stop-WithError ("server.crt or server.key already exists in $sslDir. " +
        'Run again with -Force to replace them.')
}

$work = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work | Out-Null

function Write-PemFile([string] $Path, [string] $Label, [byte[]] $Data) {
    $pem = [string]::new([PemEncoding]::Write($Label, $Data))
    [IO.File]::WriteAllText($Path, $pem + "`n")
}

function New-WithOpenSsl {
    # Empty param() block exists only so the suppression attribute below has a valid attachment
    # point (PowerShell requires an explicit param() for a function-level attribute); this function
    # takes no parameters.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes a temp OpenSSL config and the cert/key files, but is called unconditionally once per script run; the existing-file check and -Force gate are already handled by the caller before this runs, so there is no scenario where a caller wants to preview or skip it.')]
    param()
    # Same config as generate-certificate.sh.
    $config = @'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3

[dn]
CN = localhost

[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, DNS:nginx, IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
'@
    $configPath = Join-Path $work 'openssl.cnf'
    [IO.File]::WriteAllText($configPath, $config.Replace("`r`n", "`n") + "`n")

    $output = & openssl req -x509 -config $configPath -newkey rsa:2048 -sha256 -nodes -days $days `
        -keyout (Join-Path $work 'server.key') -out (Join-Path $work 'server.crt') 2>&1
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine(($output | Out-String))
        Stop-WithError 'openssl could not create the certificate.'
    }
}

function New-WithDotNet {
    # Empty param() block exists only so the suppression attribute below has a valid attachment
    # point (PowerShell requires an explicit param() for a function-level attribute); this function
    # takes no parameters.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Genuinely writes the cert/key files via .NET APIs, but is called unconditionally once per script run with the existing-file/-Force gate already handled by the caller, so there is no preview/skip use case.')]
    param()
    $rsa = [RSA]::Create(2048)
    try {
        $request = [CertificateRequest]::new(
            'CN=localhost', $rsa, [HashAlgorithmName]::SHA256, [RSASignaturePadding]::Pkcs1)
        $extensions = $request.CertificateExtensions

        $extensions.Add([X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $usage = [X509KeyUsageFlags]::DigitalSignature -bor [X509KeyUsageFlags]::KeyEncipherment
        $extensions.Add([X509KeyUsageExtension]::new($usage, $true))
        $serverAuth = [OidCollection]::new()
        [void] $serverAuth.Add([Oid]::new('1.3.6.1.5.5.7.3.1'))
        $extensions.Add([X509EnhancedKeyUsageExtension]::new($serverAuth, $false))

        $san = [SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName('localhost')
        $san.AddDnsName('nginx')
        $san.AddIpAddress([Net.IPAddress]::Parse('127.0.0.1'))
        $extensions.Add($san.Build())

        $ski = [X509SubjectKeyIdentifierExtension]::new($request.PublicKey, $false)
        $extensions.Add($ski)
        # X509AuthorityKeyIdentifierExtension exists from .NET 7 (PowerShell 7.3).
        $akiType = 'System.Security.Cryptography.X509Certificates.X509AuthorityKeyIdentifierExtension' -as
            [type]
        if ($akiType) {
            $extensions.Add($akiType::CreateFromSubjectKeyIdentifier($ski))
        }

        $now = [DateTimeOffset]::UtcNow
        $cert = $request.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays($days))
        try {
            Write-PemFile (Join-Path $work 'server.crt') 'CERTIFICATE' $cert.RawData
            Write-PemFile (Join-Path $work 'server.key') 'PRIVATE KEY' $rsa.ExportPkcs8PrivateKey()
        }
        finally {
            $cert.Dispose()
        }
    }
    finally {
        $rsa.Dispose()
    }
}

try {
    if (Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue) {
        $method = 'openssl'
        New-WithOpenSsl
    }
    else {
        $method = '.NET CertificateRequest'
        New-WithDotNet
    }

    if (-not $IsWindows) {
        & chmod 600 (Join-Path $work 'server.key')
        & chmod 644 (Join-Path $work 'server.crt')
    }
    Move-Item -Force (Join-Path $work 'server.crt') $crt
    Move-Item -Force (Join-Path $work 'server.key') $key
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host @"
Created a self-signed certificate for local development (using $method):
  $crt
  $key
  Valid for $days days. SANs: DNS:localhost, DNS:nginx, IP:127.0.0.1

Next steps:
  1. Start the kit, or run 'docker compose restart nginx' if it is already running.
  2. Clients do not trust this certificate by default. Trust server.crt in your OS or
     tool, or point the client at it, for example:
       curl --cacert ssl/server.crt https://localhost/api
       Python requests: verify="ssl/server.crt"
       Node.js: NODE_EXTRA_CA_CERTS=ssl/server.crt
  3. Keep server.key private. It is for this machine only and must not be committed.
"@
