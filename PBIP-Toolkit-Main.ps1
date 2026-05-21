#Requires -Version 5.1

<#
.SYNOPSIS
    PBIP Toolkit - Main Launcher
.DESCRIPTION
    Loads all modules and launches the PBIP Manager GUI
.NOTES
    Modular version - all logic in Modules/ folder
#>

# Determine script location
$script:ToolkitPath = if ($PSScriptRoot) { 
    $PSScriptRoot 
} else { 
    Split-Path -Parent $MyInvocation.MyCommand.Path 
}

Write-Host "`nPBIP Toolkit - Starting..." -ForegroundColor Cyan
Write-Host "Location: $script:ToolkitPath`n" -ForegroundColor Gray

# Load modules in correct order
$modulePath = Join-Path $script:ToolkitPath "Modules"

if (-not (Test-Path $modulePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Modules folder not found!`n`nExpected: $modulePath",
        "Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

Write-Host "Loading modules..." -ForegroundColor Yellow

# List of modules to load in order
$modulesToLoad = @(
    @{ Name = "Common.ps1"; Required = $true }
    @{ Name = "Manager-Core.ps1"; Required = $true }
    @{ Name = "Manager-Stats.ps1"; Required = $false }
    @{ Name = "API-Scanner.ps1"; Required = $false }
    @{ Name = "Usage-Analytics.ps1"; Required = $false }
    @{ Name = "Access-Audit.ps1"; Required = $false }
    @{ Name = "API-Operations.ps1"; Required = $false }
    @{ Name = "Scan-History.ps1"; Required = $false }
    @{ Name = "Lineage-Graph.ps1"; Required = $false }
    @{ Name = "BestPractice-Analyzer.ps1"; Required = $false }
    @{ Name = "Manager-GUI.ps1"; Required = $true }
    @{ Name = "Analyzer-Menu.ps1"; Required = $false }
    @{ Name = "Step1-Model.ps1"; Required = $false }
    @{ Name = "Step2-Tables.ps1"; Required = $false }
    @{ Name = "Step3-Roles.ps1"; Required = $false }
    @{ Name = "Step4-Expressions.ps1"; Required = $false }
)

$loadedCount = 0
$skippedCount = 0
$failedModules = @()

foreach ($module in $modulesToLoad) {
    $modulePath_Full = Join-Path $modulePath $module.Name
    
    if (Test-Path $modulePath_Full) {
        try {
            . $modulePath_Full
            Write-Host "  OK $($module.Name)" -ForegroundColor Green
            $loadedCount++
        }
        catch {
            if ($module.Required) {
                $failedModules += $module.Name
                Write-Host "  FAILED $($module.Name): $($_.Exception.Message)" -ForegroundColor Red
            }
            else {
                Write-Host "  ERROR $($module.Name) (optional)" -ForegroundColor Yellow
                $skippedCount++
            }
        }
    }
    else {
        if ($module.Required) {
            $failedModules += $module.Name
            Write-Host "  MISSING $($module.Name) (required!)" -ForegroundColor Red
        }
        else {
            Write-Host "  SKIP $($module.Name) (optional)" -ForegroundColor Gray
            $skippedCount++
        }
    }
}

Write-Host "`nModule Summary:" -ForegroundColor Cyan
Write-Host "  Loaded: $loadedCount" -ForegroundColor Green
Write-Host "  Skipped: $skippedCount" -ForegroundColor Gray

if ($failedModules.Count -gt 0) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Required modules missing or failed to load:`n`n$($failedModules -join "`n")`n`nPlease ensure all required modules are in the Modules folder.",
        "Module Load Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

Write-Host "`nLaunching PBIP Manager...`n" -ForegroundColor Green

# Launch main GUI
try {
    if (Get-Command Show-ManagerGUI -ErrorAction SilentlyContinue) {
        Show-ManagerGUI
    }
    else {
        # Temporary: If GUI not created yet, show test message
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Modules loaded successfully!`n`nManager-GUI.ps1 not created yet.`n`nReady for next step.",
            "PBIP Toolkit - Test",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Error launching GUI!`n`n$($_.Exception.Message)",
        "Launch Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}
