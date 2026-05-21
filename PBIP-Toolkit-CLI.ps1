#Requires -Version 5.1
<#
.SYNOPSIS
    PBIP Toolkit - headless / CI runner.
.DESCRIPTION
    Runs PBIP Toolkit governance operations with no GUI, for Task Scheduler,
    Azure DevOps, GitHub Actions and similar. Loads the engine modules only
    (no WinForms windows are shown), writes exports under
    <GovernanceRoot>\Analysis_Output, prints a summary and sets an exit code:

        0  success, nothing flagged
        1  a runtime error occurred
        2  a quality gate failed (-FailOnHighFindings / -FailOnDrift)

.PARAMETER GovernanceRoot
    Governance root folder (contains the WS\ tree).
.PARAMETER Task
    One or more of: scan, generate, apiscan, usage, bestpractice, snapshot,
    lineage, all. 'all' runs every task except 'generate' (extraction is
    opt-in - it needs pbi-tools and Power BI Desktop).
.PARAMETER TenantId / ClientId / ClientSecret
    Service principal for the admin-API tasks (apiscan, usage, lineage).
    Without them those tasks are skipped - headless mode never prompts.
.PARAMETER UsageDays
    Days of activity history for the usage task (1-30, default 30).
.PARAMETER FailOnHighFindings
    Exit 2 if the best-practice analyzer reports any High-severity finding.
.PARAMETER FailOnDrift
    Exit 2 if the API scan finds models in the tenant missing from the
    Governance folder, or local files orphaned from the tenant.
.EXAMPLE
    .\PBIP-Toolkit-CLI.ps1 -GovernanceRoot C:\Governance -Task scan,bestpractice -FailOnHighFindings
.EXAMPLE
    .\PBIP-Toolkit-CLI.ps1 -GovernanceRoot C:\Governance -Task all `
        -TenantId $env:PBI_TENANT -ClientId $env:PBI_CLIENT -ClientSecret $env:PBI_SECRET
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GovernanceRoot,
    [ValidateSet('scan','generate','apiscan','usage','access','bestpractice','snapshot','lineage','all')]
    [string[]]$Task = @('scan'),
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [ValidateRange(1,30)][int]$UsageDays = 30,
    [switch]$FailOnHighFindings,
    [switch]$FailOnDrift,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Write-Cli {
    param([string]$Message, [string]$Color = "Gray")
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}
function Write-CliHead {
    param([string]$Text)
    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor DarkCyan
        Write-Host "  $Text" -ForegroundColor Cyan
        Write-Host ("=" * 70) -ForegroundColor DarkCyan
    }
}

# --- Load engine modules (no GUI modules) ----------------------------------
$toolkitPath = if ($PSScriptRoot) { $PSScriptRoot }
               else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$modulePath  = Join-Path $toolkitPath "Modules"
if (-not (Test-Path $modulePath)) {
    Write-Host "Modules folder not found: $modulePath" -ForegroundColor Red
    exit 1
}
$engineModules = @(
    "Common.ps1", "Manager-Core.ps1", "API-Scanner.ps1", "Usage-Analytics.ps1",
    "Access-Audit.ps1", "Scan-History.ps1", "Lineage-Graph.ps1", "BestPractice-Analyzer.ps1"
)
try {
    foreach ($m in $engineModules) {
        $p = Join-Path $modulePath $m
        if (Test-Path $p) { . $p } else { throw "Missing module: $m" }
    }
}
catch {
    Write-Host "Failed to load modules: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $GovernanceRoot)) {
    Write-Host "Governance root not found: $GovernanceRoot" -ForegroundColor Red
    exit 1
}

# --- Plan tasks -------------------------------------------------------------
$tasks = if ($Task -contains 'all') {
    @('scan','apiscan','usage','access','bestpractice','snapshot','lineage')
} else { $Task }

$hasCreds = $TenantId -and $ClientId -and $ClientSecret
$state    = @{ ScanResults = $null; Inventory = $null }
$gateFailed = $false
$exitCode   = 0

Write-Cli "PBIP Toolkit CLI - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "White"
Write-Cli "Governance root: $GovernanceRoot"
Write-Cli "Tasks: $($tasks -join ', ')"

# --- Connect once if any admin-API task is planned --------------------------
$needsApi = ($tasks | Where-Object { $_ -in 'apiscan','usage','access','lineage' }).Count -gt 0
if ($needsApi) {
    if (-not $hasCreds) {
        Write-Cli "No service principal supplied - admin-API tasks will be skipped." "Yellow"
    }
    else {
        try {
            Connect-PbiApi -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret | Out-Null
            Write-Cli "Connected to Power BI API ($ClientId)." "Green"
        }
        catch {
            Write-Host "API sign-in failed: $($_.Exception.Message)" -ForegroundColor Red
            $hasCreds = $false
            $exitCode = 1
        }
    }
}

# --- Run tasks in dependency order -----------------------------------------
try {
    if ($tasks -contains 'scan' -or $tasks -contains 'generate' -or $tasks -contains 'snapshot') {
        Write-CliHead "Folder scan"
        $state.ScanResults = @(Scan-GovernanceStructure -RootPath $GovernanceRoot)
        $existing = @($state.ScanResults | Where-Object { $_.PbipExists }).Count
        Write-Cli ("Models: {0}  |  PBIP present: {1}  |  missing: {2}" -f `
            $state.ScanResults.Count, $existing, ($state.ScanResults.Count - $existing)) "White"
    }

    if ($tasks -contains 'generate') {
        Write-CliHead "Generate PBIP (extraction)"
        $pbiTools = Find-PbiTools -GovernanceRoot $GovernanceRoot
        if (-not $pbiTools) {
            Write-Cli "pbi-tools not found - skipping extraction." "Yellow"
        }
        else {
            $missing = @($state.ScanResults | Where-Object { -not $_.PbipExists })
            Write-Cli "Extracting $($missing.Count) model(s)..."
            foreach ($mdl in $missing) {
                try {
                    & $pbiTools extract $mdl.PbixFile -extractFolder $mdl.PbipFolderPath 2>&1 | Out-Null
                    $dataFolder = Join-Path $mdl.PbipFolderPath "Data"
                    if (Test-Path $dataFolder) { Remove-Item $dataFolder -Recurse -Force -ErrorAction SilentlyContinue }
                    Write-Cli "  extracted: $($mdl.ModelName)" "Green"
                }
                catch { Write-Cli "  FAILED: $($mdl.ModelName) - $($_.Exception.Message)" "Red" }
            }
        }
    }

    if ($tasks -contains 'apiscan' -and $hasCreds) {
        Write-CliHead "API tenant scan"
        $raw = Start-PbiTenantScan
        $state.Inventory = ConvertTo-PbiInventory -ScanResults $raw
        Write-Cli ("Tenant: {0} workspaces, {1} datasets, {2} reports" -f `
            @($state.Inventory.Workspaces).Count, @($state.Inventory.Datasets).Count, `
            @($state.Inventory.Reports).Count) "White"
        Export-PbiApiInventory -Inventory $state.Inventory -GovernanceRoot $GovernanceRoot | Out-Null
        if ($state.ScanResults) {
            $cmp = Compare-GovernanceToService -LocalScan $state.ScanResults -Inventory $state.Inventory
            $driftCount = @($cmp.MissingLocally).Count + @($cmp.OrphanedLocal).Count
            Write-Cli ("Drift: {0} not in Governance folder, {1} local orphan(s)" -f `
                @($cmp.MissingLocally).Count, @($cmp.OrphanedLocal).Count) "White"
            if ($FailOnDrift -and $driftCount -gt 0) {
                Write-Cli "Quality gate: drift detected (-FailOnDrift)." "Red"
                $gateFailed = $true
            }
        }
    }

    if ($tasks -contains 'usage' -and $hasCreds) {
        Write-CliHead "Usage & adoption"
        $events  = Get-PbiActivityEvents -Days $UsageDays
        $summary = Get-UsageSummary -Events $events -Inventory $state.Inventory
        Write-Cli ("Views: {0}  |  distinct users: {1}  |  unused reports: {2}" -f `
            $summary.ViewCount, $summary.DistinctUsers, @($summary.UnusedReports).Count) "White"
        Export-UsageReport -Summary $summary -GovernanceRoot $GovernanceRoot | Out-Null
    }

    if ($tasks -contains 'access' -and $hasCreds) {
        Write-CliHead "Workspace access audit"
        $access = Get-WorkspaceAccess
        $audit  = Get-AccessAudit -WorkspaceAccess $access
        Write-Cli ("Workspaces: {0}  |  no admin: {1}  |  single admin: {2}  |  with external: {3}" -f `
            $audit.Summary.WorkspaceCount, $audit.Summary.NoAdmin, `
            $audit.Summary.SingleAdmin, $audit.Summary.WithExternal) "White"
        Export-AccessAudit -Audit $audit -GovernanceRoot $GovernanceRoot | Out-Null
    }

    if ($tasks -contains 'bestpractice') {
        Write-CliHead "Best-practice analysis"
        $bp = Invoke-BestPracticeAnalysis -GovernanceRoot $GovernanceRoot
        Write-Cli ("Models: {0}  |  findings: {1}" -f $bp.ModelsAnalyzed, @($bp.Violations).Count) "White"
        foreach ($s in $bp.SeverityCounts) { Write-Cli ("  {0}: {1}" -f $s.Severity, $s.Count) }
        if (@($bp.Violations).Count -gt 0) {
            Export-BestPracticeReport -Result $bp -GovernanceRoot $GovernanceRoot | Out-Null
        }
        $high = @($bp.Violations | Where-Object { $_.Severity -eq 'High' }).Count
        if ($FailOnHighFindings -and $high -gt 0) {
            Write-Cli "Quality gate: $high High-severity finding(s) (-FailOnHighFindings)." "Red"
            $gateFailed = $true
        }
    }

    if ($tasks -contains 'snapshot') {
        Write-CliHead "Scan-history snapshot"
        if ($state.ScanResults) {
            $snap = Save-ScanSnapshot -ScanResults $state.ScanResults -GovernanceRoot $GovernanceRoot
            Write-Cli "Snapshot saved: $(Split-Path $snap -Leaf)" "Green"
        }
        else { Write-Cli "No scan results - snapshot skipped." "Yellow" }
    }

    if ($tasks -contains 'lineage') {
        Write-CliHead "Lineage graph"
        if (-not $state.Inventory) {
            Write-Cli "No API inventory - run with apiscan (and credentials) to build lineage. Skipped." "Yellow"
        }
        else {
            $graph = Build-LineageGraph -Inventory $state.Inventory -LocalScan $state.ScanResults
            $stats = Get-LineageStats -Graph $graph
            $html  = Export-LineageGraph -Graph $graph -Stats $stats -GovernanceRoot $GovernanceRoot
            Write-Cli ("Graph: {0} nodes, {1} links -> {2}" -f $stats.NodeCount, $stats.LinkCount, $html) "White"
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Result -----------------------------------------------------------------
Write-CliHead "Done"
if ($gateFailed) {
    Write-Cli "Result: quality gate FAILED." "Red"
    $exitCode = 2
}
elseif ($exitCode -eq 0) {
    Write-Cli "Result: OK." "Green"
}
exit $exitCode
