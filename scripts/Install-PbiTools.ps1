#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads pbi-tools (Desktop edition) and unpacks it next to the toolkit.
.DESCRIPTION
    The PBIP Toolkit relies on pbi-tools.exe to extract .pbix files into the
    PBIP / TMDL source format. pbi-tools is a separate open-source project
    (AGPL-3.0) and is intentionally NOT bundled in this repository, so the
    repository can stay under the MIT license. Run this script once to fetch it.

    By default it installs into <repo>\pbi-tools\, which Find-PbiTools (in
    Common.ps1) probes automatically.
.PARAMETER Version
    pbi-tools release tag to download. Defaults to 1.2.0.
.PARAMETER Destination
    Folder to unpack into. Defaults to <repo root>\pbi-tools.
.EXAMPLE
    .\scripts\Install-PbiTools.ps1
.NOTES
    pbi-tools project: https://github.com/pbi-tools/pbi-tools
    The Desktop edition requires Power BI Desktop to be installed on the machine.
#>
param(
    [string]$Version = "1.2.0",
    [string]$Destination
)

$ErrorActionPreference = "Stop"

# Resolve <repo root> = parent of the folder this script lives in.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Destination) { $Destination = Join-Path $repoRoot "pbi-tools" }

$asset   = "pbi-tools.$Version.zip"
$url     = "https://github.com/pbi-tools/pbi-tools/releases/download/$Version/$asset"
$tmpZip  = Join-Path $env:TEMP $asset

Write-Host "PBIP Toolkit - pbi-tools installer" -ForegroundColor Cyan
Write-Host "  Version    : $Version"
Write-Host "  Source     : $url"
Write-Host "  Destination: $Destination`n"

if (Test-Path (Join-Path $Destination "pbi-tools.exe")) {
    Write-Host "pbi-tools.exe already present at $Destination - nothing to do." -ForegroundColor Green
    return
}

Write-Host "Downloading..." -ForegroundColor Yellow
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
}
catch {
    Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Download $asset manually from:" -ForegroundColor Yellow
    Write-Host "  https://github.com/pbi-tools/pbi-tools/releases/tag/$Version" -ForegroundColor Yellow
    Write-Host "and extract it into: $Destination" -ForegroundColor Yellow
    return
}

Write-Host "Extracting..." -ForegroundColor Yellow
if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
Expand-Archive -Path $tmpZip -DestinationPath $Destination -Force
Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

$exe = Join-Path $Destination "pbi-tools.exe"
if (Test-Path $exe) {
    Write-Host "`nInstalled: $exe" -ForegroundColor Green
    & $exe info 2>$null | Select-Object -First 1
}
else {
    Write-Host "`nExtraction finished but pbi-tools.exe was not found in $Destination." -ForegroundColor Red
}
