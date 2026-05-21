# API-Scanner.ps1
# Power BI REST API scanner module for the PBIP Toolkit.
#
# Adds a tenant-level metadata scan on top of the local folder scan. It uses the
# Power BI Admin "Scanner API" (metadata scanning) to inventory every workspace,
# semantic model (dataset), report, dataflow and data source in the tenant, then
# reconciles that live inventory against the local Governance/WS folder structure
# to surface drift: models present in the service but missing locally, and local
# files that no longer correspond to a live dataset.
#
# Requirements:
#   - An Entra ID (Azure AD) app registration (service principal) with the
#     Power BI tenant setting "Allow service principals to use read-only admin
#     APIs" enabled, OR an interactive admin sign-in.
#   - Scanner API permissions: Tenant.Read.All (no workspace membership needed).
#
# Docs: https://learn.microsoft.com/rest/api/power-bi/admin/workspace-info-get-scan-result
#       https://learn.microsoft.com/power-bi/enterprise/service-admin-metadata-scanning

#region Configuration

$script:PbiApiBase     = "https://api.powerbi.com/v1.0/myorg"
$script:PbiResourceUrl = "https://analysis.windows.net/powerbi/api"
$script:PbiApiToken    = $null   # current bearer token
$script:PbiApiTokenExp = [datetime]::MinValue
$script:PbiApiContext  = $null   # describes how we authenticated
$script:LastApiScan    = $null   # cached flattened inventory

#endregion

#region Authentication

function Connect-PbiApi {
    <#
    .SYNOPSIS
        Acquires a Power BI access token, either via a service principal
        (unattended) or interactively through the MicrosoftPowerBIMgmt module.
    .PARAMETER TenantId
        Entra ID tenant GUID. Required for service principal auth.
    .PARAMETER ClientId
        App registration (client) ID. Required for service principal auth.
    .PARAMETER ClientSecret
        App client secret. If omitted, interactive sign-in is used instead.
    #>
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    # --- Service principal (client credentials) flow -----------------------
    if ($TenantId -and $ClientId -and $ClientSecret) {
        $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$script:PbiResourceUrl/.default"
        }
        try {
            $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body `
                        -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
            $script:PbiApiToken    = $resp.access_token
            $script:PbiApiTokenExp = (Get-Date).AddSeconds([int]$resp.expires_in - 120)
            $script:PbiApiContext  = "Service principal ($ClientId)"
            return $true
        }
        catch {
            throw "Service principal sign-in failed: $($_.Exception.Message)"
        }
    }

    # --- Interactive flow via MicrosoftPowerBIMgmt -------------------------
    if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt.Profile)) {
        throw @"
Interactive sign-in needs the MicrosoftPowerBIMgmt module. Install it once with:

    Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser -Force

Or supply -TenantId / -ClientId / -ClientSecret to use a service principal.
"@
    }

    Import-Module MicrosoftPowerBIMgmt.Profile -ErrorAction Stop
    Connect-PowerBIServiceAccount -ErrorAction Stop | Out-Null
    $token = (Get-PowerBIAccessToken -AsString -ErrorAction Stop)
    # Get-PowerBIAccessToken returns "Bearer eyJ..."; strip the prefix.
    $script:PbiApiToken    = $token -replace '^Bearer\s+', ''
    $script:PbiApiTokenExp = (Get-Date).AddMinutes(50)
    $script:PbiApiContext  = "Interactive (MicrosoftPowerBIMgmt)"
    return $true
}

function Test-PbiApiConnection {
    return ($script:PbiApiToken -and (Get-Date) -lt $script:PbiApiTokenExp)
}

#endregion

#region REST helper

function Invoke-PbiRestApi {
    <#
    .SYNOPSIS
        Calls a Power BI REST endpoint with the cached bearer token. Handles
        HTTP 429 (throttling) with Retry-After back-off.
    .PARAMETER Path
        Path relative to https://api.powerbi.com/v1.0/myorg (leading slash optional).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet("GET","POST")][string]$Method = "GET",
        $Body,
        [int]$MaxRetries = 5
    )

    if (-not (Test-PbiApiConnection)) {
        throw "Not connected to the Power BI API. Run Connect-PbiApi first."
    }

    $uri = if ($Path -match '^https?://') { $Path }
           else { "$script:PbiApiBase/$($Path.TrimStart('/'))" }

    $headers = @{ Authorization = "Bearer $script:PbiApiToken" }
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $params = @{
                Uri         = $uri
                Method      = $Method
                Headers     = $headers
                ErrorAction = "Stop"
            }
            if ($Body -ne $null) {
                $params.Body        = ($Body | ConvertTo-Json -Depth 10)
                $params.ContentType = "application/json"
            }
            return Invoke-RestMethod @params
        }
        catch {
            $resp = $_.Exception.Response
            $code = if ($resp) { [int]$resp.StatusCode } else { 0 }

            if ($code -eq 429 -and $attempt -le $MaxRetries) {
                $wait = 30
                if ($resp.Headers -and $resp.Headers["Retry-After"]) {
                    $wait = [int]$resp.Headers["Retry-After"]
                }
                Write-Host "  API throttled (429). Waiting $wait s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                continue
            }
            if ($code -in 502,503,504 -and $attempt -le $MaxRetries) {
                Start-Sleep -Seconds ([Math]::Min(60, 5 * $attempt))
                continue
            }
            throw "API call failed ($code) on $uri : $($_.Exception.Message)"
        }
    }
}

#endregion

#region Scanner API workflow

function Start-PbiTenantScan {
    <#
    .SYNOPSIS
        Runs the full Scanner API workflow and returns the raw scan result(s).
    .DESCRIPTION
        1. GET  admin/workspaces/modified            - list workspace IDs
        2. POST admin/workspaces/getInfo             - queue a scan (max 100 ids)
        3. GET  admin/workspaces/scanStatus/{id}     - poll until Succeeded
        4. GET  admin/workspaces/scanResult/{id}     - download metadata payload
    .PARAMETER ModifiedSince
        Optional datetime. When supplied, only workspaces changed since then are
        scanned (incremental). Omit for a full tenant scan.
    #>
    param(
        [datetime]$ModifiedSince,
        [scriptblock]$ProgressCallback
    )

    function _report($msg, $pct) {
        Write-Host "  $msg" -ForegroundColor Gray
        if ($ProgressCallback) { & $ProgressCallback $msg $pct }
    }

    # 1. Modified workspaces -------------------------------------------------
    $modPath = "admin/workspaces/modified?excludePersonalWorkspaces=True"
    if ($ModifiedSince) {
        $iso = $ModifiedSince.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        $modPath += "&modifiedSince=$iso"
    }
    _report "Listing workspaces..." 5
    $modified = Invoke-PbiRestApi -Path $modPath
    $workspaceIds = @($modified | ForEach-Object { $_.id })
    if ($workspaceIds.Count -eq 0) {
        _report "No workspaces returned." 100
        return @()
    }
    _report "Found $($workspaceIds.Count) workspaces to scan." 10

    # 2-4. Batch into groups of 100 -----------------------------------------
    $batchSize = 100
    $batches   = [Math]::Ceiling($workspaceIds.Count / $batchSize)
    $results   = @()

    for ($b = 0; $b -lt $batches; $b++) {
        $slice = $workspaceIds[($b * $batchSize)..([Math]::Min(($b + 1) * $batchSize - 1, $workspaceIds.Count - 1))]
        $basePct = 10 + [int](($b / $batches) * 80)

        # getInfo - request the richest payload the Scanner API offers
        $infoPath = "admin/workspaces/getInfo?" + (@(
            "lineage=true"
            "datasourceDetails=true"
            "datasetSchema=true"
            "datasetExpressions=true"
            "getArtifactUsers=true"
        ) -join "&")
        _report "Batch $($b + 1)/$batches : queueing scan for $($slice.Count) workspaces..." $basePct
        $scan = Invoke-PbiRestApi -Path $infoPath -Method POST -Body @{ workspaces = $slice }
        $scanId = $scan.id

        # poll status
        $status = "NotStarted"
        $polls  = 0
        while ($status -notin "Succeeded","Failed" -and $polls -lt 120) {
            Start-Sleep -Seconds 5
            $polls++
            $st = Invoke-PbiRestApi -Path "admin/workspaces/scanStatus/$scanId"
            $status = $st.status
            _report "Batch $($b + 1)/$batches : scan status = $status" ($basePct + 3)
        }
        if ($status -ne "Succeeded") {
            throw "Scan $scanId did not succeed (status: $status)."
        }

        # result
        _report "Batch $($b + 1)/$batches : downloading metadata..." ($basePct + 6)
        $results += Invoke-PbiRestApi -Path "admin/workspaces/scanResult/$scanId"
    }

    _report "Tenant scan complete." 100
    return $results
}

#endregion

#region Flatten / inventory

function ConvertTo-PbiInventory {
    <#
    .SYNOPSIS
        Flattens raw Scanner API result(s) into tidy PSCustomObject collections:
        Workspaces, Datasets, Reports, Dataflows, DataSources.
    #>
    param([Parameter(Mandatory)]$ScanResults)

    $workspaces  = @()
    $datasets    = @()
    $reports     = @()
    $dataflows   = @()
    $dataSources = @()

    foreach ($result in @($ScanResults)) {

        # Tenant-wide datasource instances (siblings of 'workspaces' in the
        # scan result). datasourceId here matches dataset.datasourceUsages
        # [].datasourceInstanceId, which is how models get linked to a source.
        foreach ($dsi in @($result.datasourceInstances)) {
            $cd = $dsi.connectionDetails
            $detailParts = @($cd.server, $cd.database, $cd.url, $cd.path,
                             $cd.account, $cd.domain, $cd.kind, $cd.connectionString) |
                           Where-Object { $_ }
            $dataSources += [PSCustomObject]@{
                DatasourceId = $dsi.datasourceId
                Type         = $dsi.datasourceType
                Server       = $cd.server
                Database     = $cd.database
                Url          = $cd.url
                Path         = $cd.path
                Detail       = ($detailParts -join " / ")
                GatewayId    = $dsi.gatewayId
            }
        }

        foreach ($ws in @($result.workspaces)) {
            $workspaces += [PSCustomObject]@{
                WorkspaceId   = $ws.id
                WorkspaceName = $ws.name
                Type          = $ws.type
                State         = $ws.state
                IsOnDedicated = $ws.isOnDedicatedCapacity
                CapacityId    = $ws.capacityId
                DatasetCount  = @($ws.datasets).Count
                ReportCount   = @($ws.reports).Count
                DataflowCount = @($ws.dataflows).Count
            }

            foreach ($ds in @($ws.datasets)) {
                $datasets += [PSCustomObject]@{
                    WorkspaceId       = $ws.id
                    WorkspaceName     = $ws.name
                    DatasetId         = $ds.id
                    DatasetName       = $ds.name
                    ConfiguredBy      = $ds.configuredBy
                    Endorsement       = $ds.endorsementDetails.endorsement
                    SensitivityLabel  = $ds.sensitivityLabel.labelId
                    TableCount        = @($ds.tables).Count
                    HasRLS            = (@($ds.tables).Count -gt 0 -and ($ds.PSObject.Properties.Name -contains 'roles') -and @($ds.roles).Count -gt 0)
                    ContentProviderType = $ds.contentProviderType
                    CreatedDate       = $ds.createdDate
                    DatasourceInstanceIds = @(@($ds.datasourceUsages) |
                        ForEach-Object { $_.datasourceInstanceId } | Where-Object { $_ })
                    UpstreamDatasets  = @(@($ds.upstreamDatasets) |
                        ForEach-Object { if ($_.targetDatasetId) { $_.targetDatasetId } else { $_ } } |
                        Where-Object { $_ })
                }
            }
            foreach ($rp in @($ws.reports)) {
                $reports += [PSCustomObject]@{
                    WorkspaceId   = $ws.id
                    WorkspaceName = $ws.name
                    ReportId      = $rp.id
                    ReportName    = $rp.name
                    ReportType    = $rp.reportType
                    DatasetId     = $rp.datasetId
                    CreatedBy     = $rp.createdBy
                    ModifiedDate  = $rp.modifiedDateTime
                }
            }
            foreach ($df in @($ws.dataflows)) {
                $dataflows += [PSCustomObject]@{
                    WorkspaceId   = $ws.id
                    WorkspaceName = $ws.name
                    DataflowId    = $df.objectId
                    DataflowName  = $df.name
                    ConfiguredBy  = $df.configuredBy
                }
            }
        }
    }

    $inventory = [PSCustomObject]@{
        ScanDate    = Get-Date
        Workspaces  = $workspaces
        Datasets    = $datasets
        Reports     = $reports
        Dataflows   = $dataflows
        DataSources = $dataSources
    }
    $script:LastApiScan = $inventory
    return $inventory
}

#endregion

#region Reconciliation against the local folder scan

function Compare-GovernanceToService {
    <#
    .SYNOPSIS
        Cross-references the local Governance/WS scan (Scan-GovernanceStructure
        output) with the live tenant inventory. Produces a drift report.
    .PARAMETER LocalScan
        Output of Scan-GovernanceStructure (the $script:ScanResults array).
    .PARAMETER Inventory
        Output of ConvertTo-PbiInventory.
    #>
    param(
        [Parameter(Mandatory)]$LocalScan,
        [Parameter(Mandatory)]$Inventory
    )

    $localById = @{}
    foreach ($m in @($LocalScan)) {
        if ($m.DatasetId) { $localById[$m.DatasetId.ToLower()] = $m }
    }
    $serviceById = @{}
    foreach ($d in @($Inventory.Datasets)) {
        if ($d.DatasetId) { $serviceById[$d.DatasetId.ToLower()] = $d }
    }

    # Models live in the tenant but not captured in the Governance folder
    $missingLocally = foreach ($d in @($Inventory.Datasets)) {
        if ($d.DatasetId -and -not $localById.ContainsKey($d.DatasetId.ToLower())) {
            [PSCustomObject]@{
                Issue         = "NOT IN GOVERNANCE FOLDER"
                WorkspaceName = $d.WorkspaceName
                DatasetName   = $d.DatasetName
                DatasetId     = $d.DatasetId
                ConfiguredBy  = $d.ConfiguredBy
            }
        }
    }

    # Local files whose dataset no longer exists in the tenant (orphans)
    $orphanedLocal = foreach ($m in @($LocalScan)) {
        if ($m.DatasetId -and -not $serviceById.ContainsKey($m.DatasetId.ToLower())) {
            [PSCustomObject]@{
                Issue         = "ORPHAN - DATASET NOT IN TENANT"
                WorkspaceName = $m.WorkspaceName
                ModelName     = $m.ModelName
                DatasetId     = $m.DatasetId
                PbixFile      = $m.PbixFile
            }
        }
    }

    # Models present in both - the healthy, governed set, enriched with
    # ownership and endorsement pulled from the live service.
    $matched = foreach ($m in @($LocalScan)) {
        if ($m.DatasetId -and $serviceById.ContainsKey($m.DatasetId.ToLower())) {
            $svc = $serviceById[$m.DatasetId.ToLower()]
            $endorse = if ([string]::IsNullOrEmpty($svc.Endorsement)) { "None" } else { $svc.Endorsement }
            [PSCustomObject]@{
                WorkspaceName    = $m.WorkspaceName
                ModelName        = $m.ModelName
                DatasetName      = $svc.DatasetName
                DatasetId        = $m.DatasetId
                Owner            = $svc.ConfiguredBy
                Endorsement      = $endorse
                SensitivityLabel = $svc.SensitivityLabel
                LocalPbipExists  = $m.PbipExists
            }
        }
    }

    # Ownership / endorsement summary across the matched (governed) set.
    $matchedArr  = @($matched)
    $endorseSum  = $matchedArr | Group-Object Endorsement |
                       ForEach-Object { "{0}: {1}" -f $_.Name, $_.Count }
    $unowned     = @($matchedArr | Where-Object { [string]::IsNullOrEmpty($_.Owner) })
    $uncertified = @($matchedArr | Where-Object { $_.Endorsement -notin @("Certified","Promoted") })

    return [PSCustomObject]@{
        Matched          = $matchedArr
        MissingLocally   = @($missingLocally)
        OrphanedLocal    = @($orphanedLocal)
        ServiceDatasets  = @($Inventory.Datasets).Count
        LocalModels      = @($LocalScan).Count
        MatchedCount     = $matchedArr.Count
        CoveragePercent  = if (@($Inventory.Datasets).Count -gt 0) {
                               [math]::Round(($matchedArr.Count / @($Inventory.Datasets).Count) * 100, 1)
                           } else { 0 }
        EndorsementSummary = @($endorseSum)
        UnownedModels      = $unowned
        UncertifiedModels  = $uncertified
    }
}

#endregion

#region Refresh history (operational health)

function Get-DatasetRefreshHistory {
    <#
    .SYNOPSIS
        Returns the recent refresh history for a single dataset.
    .DESCRIPTION
        Calls GET groups/{workspaceId}/datasets/{datasetId}/refreshes. This is
        NOT an admin endpoint - the signed-in user or service principal must
        have access to the workspace. Access failures are returned as a single
        record with Status = "NoAccess" rather than throwing.
    .PARAMETER Top
        Number of refresh entries to return (default 5).
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$DatasetId,
        [int]$Top = 5
    )
    try {
        $resp = Invoke-PbiRestApi -Path "groups/$WorkspaceId/datasets/$DatasetId/refreshes?`$top=$Top"
        $rows = foreach ($r in @($resp.value)) {
            $start = [datetime]::MinValue
            $end   = [datetime]::MinValue
            $okS = [datetime]::TryParse([string]$r.startTime, [ref]$start)
            $okE = [datetime]::TryParse([string]$r.endTime,   [ref]$end)
            $dur = if ($okS -and $okE) { [math]::Round(($end - $start).TotalMinutes, 1) } else { $null }
            [PSCustomObject]@{
                DatasetId    = $DatasetId
                Status       = $r.status
                RefreshType  = $r.refreshType
                StartTime    = $r.startTime
                EndTime      = $r.endTime
                DurationMin  = $dur
                Error        = if ($r.serviceExceptionJson) { $r.serviceExceptionJson } else { "" }
            }
        }
        return @($rows)
    }
    catch {
        return @([PSCustomObject]@{
            DatasetId   = $DatasetId
            Status      = "NoAccess"
            RefreshType = ""
            StartTime   = ""
            EndTime     = ""
            DurationMin = $null
            Error       = $_.Exception.Message
        })
    }
}

function Get-RefreshHealthReport {
    <#
    .SYNOPSIS
        Builds a one-row-per-model refresh-health summary for a set of models
        that carry both a WorkspaceId and a DatasetId (e.g. the local folder
        scan results, or Compare-GovernanceToService -> Matched).
    #>
    param(
        [Parameter(Mandatory)]$Models,
        [scriptblock]$ProgressCallback
    )
    $report = @()
    $list = @($Models | Where-Object { $_.WorkspaceId -and $_.DatasetId })
    $i = 0
    foreach ($m in $list) {
        $i++
        if ($ProgressCallback) {
            & $ProgressCallback ("Refresh history $i/$($list.Count): $($m.ModelName)") ([int](($i / [Math]::Max(1,$list.Count)) * 100))
        }
        $hist   = Get-DatasetRefreshHistory -WorkspaceId $m.WorkspaceId -DatasetId $m.DatasetId -Top 5
        $last   = $hist | Select-Object -First 1
        $fails  = @($hist | Where-Object { $_.Status -eq "Failed" }).Count
        $report += [PSCustomObject]@{
            WorkspaceName   = $m.WorkspaceName
            ModelName       = $m.ModelName
            DatasetId       = $m.DatasetId
            LastStatus      = $last.Status
            LastRefresh     = $last.StartTime
            LastDurationMin = $last.DurationMin
            FailuresInLast5 = $fails
            LastError       = $last.Error
        }
    }
    return @($report)
}

#endregion

#region Export

function Export-PbiApiInventory {
    <#
    .SYNOPSIS
        Writes the inventory to JSON plus one CSV per object type, under
        <GovernanceRoot>\Analysis_Output.
    #>
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $out = Join-Path $GovernanceRoot "Analysis_Output"
    if (-not (Test-Path $out)) { New-Item -Path $out -ItemType Directory -Force | Out-Null }
    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"

    $jsonPath = Join-Path $out "ApiScan_$ts.json"
    $Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

    foreach ($set in "Workspaces","Datasets","Reports","Dataflows") {
        $rows = $Inventory.$set
        if (@($rows).Count -gt 0) {
            $csv = Join-Path $out "ApiScan_${set}_$ts.csv"
            $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        }
    }
    Write-Host "API inventory exported to: $out" -ForegroundColor Green
    return $jsonPath
}

#endregion

#region GUI

function Show-ApiScannerWindow {
    <#
    .SYNOPSIS
        Window for running a tenant scan and viewing the drift report. Designed
        to be opened from the main Manager GUI.
    .PARAMETER LocalScan
        Current $script:ScanResults from the folder scan (may be empty).
    .PARAMETER GovernanceRoot
        Governance root path, used for exports.
    #>
    param(
        $LocalScan = @(),
        [string]$GovernanceRoot = ""
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Power BI API Scanner"
    $form.Size = New-Object System.Drawing.Size(1340, 680)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(860, 20)
    $lbl.Text = "Scan the Power BI tenant via the Admin Scanner API, then reconcile against the local Governance folder."
    $form.Controls.Add($lbl)

    # --- Auth inputs -------------------------------------------------------
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "Authentication"
    $grp.Location = New-Object System.Drawing.Point(12, 38)
    $grp.Size = New-Object System.Drawing.Size(860, 110)
    $form.Controls.Add($grp)

    $mkLabel = {
        param($t,$x,$y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $t; $l.Location = New-Object System.Drawing.Point($x,$y)
        $l.Size = New-Object System.Drawing.Size(90,20); $grp.Controls.Add($l); $l
    }
    $mkBox = {
        param($x,$y,$w,$pwd)
        $b = New-Object System.Windows.Forms.TextBox
        $b.Location = New-Object System.Drawing.Point($x,$y)
        $b.Size = New-Object System.Drawing.Size($w,20)
        if ($pwd) { $b.UseSystemPasswordChar = $true }
        $grp.Controls.Add($b); $b
    }
    & $mkLabel "Tenant ID:" 10 25     | Out-Null; $txtTenant = & $mkBox 105 23 250 $false
    & $mkLabel "Client ID:" 370 25    | Out-Null; $txtClient = & $mkBox 465 23 250 $false
    & $mkLabel "Client secret:" 10 55 | Out-Null; $txtSecret = & $mkBox 105 53 250 $true
    $lblHint = & $mkLabel "Leave the three fields blank to sign in interactively as an admin." 370 55
    $lblHint.Size = New-Object System.Drawing.Size(380,40)

    # --- Action buttons ----------------------------------------------------
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Location = New-Object System.Drawing.Point(12, 158)
    $btnScan.Size = New-Object System.Drawing.Size(160, 32)
    $btnScan.Text = "Run Tenant Scan"
    $btnScan.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnScan)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Location = New-Object System.Drawing.Point(182, 158)
    $btnExport.Size = New-Object System.Drawing.Size(150, 32)
    $btnExport.Text = "Export Inventory"
    $btnExport.Enabled = $false
    $form.Controls.Add($btnExport)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Location = New-Object System.Drawing.Point(342, 158)
    $btnRefresh.Size = New-Object System.Drawing.Size(150, 32)
    $btnRefresh.Text = "Refresh Health"
    $btnRefresh.BackColor = [System.Drawing.Color]::LightBlue
    $form.Controls.Add($btnRefresh)

    $btnLineage = New-Object System.Windows.Forms.Button
    $btnLineage.Location = New-Object System.Drawing.Point(502, 158)
    $btnLineage.Size = New-Object System.Drawing.Size(150, 32)
    $btnLineage.Text = "Lineage Graph"
    $btnLineage.BackColor = [System.Drawing.Color]::Khaki
    $form.Controls.Add($btnLineage)

    $btnUsage = New-Object System.Windows.Forms.Button
    $btnUsage.Location = New-Object System.Drawing.Point(662, 158)
    $btnUsage.Size = New-Object System.Drawing.Size(150, 32)
    $btnUsage.Text = "Usage Analytics"
    $btnUsage.BackColor = [System.Drawing.Color]::LightBlue
    $form.Controls.Add($btnUsage)

    $btnAccess = New-Object System.Windows.Forms.Button
    $btnAccess.Location = New-Object System.Drawing.Point(822, 158)
    $btnAccess.Size = New-Object System.Drawing.Size(150, 32)
    $btnAccess.Text = "Access Audit"
    $btnAccess.BackColor = [System.Drawing.Color]::LightBlue
    $form.Controls.Add($btnAccess)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(982, 162)
    $progress.Size = New-Object System.Drawing.Size(340, 24)
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 200)
    $output.Size = New-Object System.Drawing.Size(1300, 400)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.DetectUrls = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $output.Add_LinkClicked({ param($s,$e) Start-Process $e.LinkText })
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 608)
    $status.Size = New-Object System.Drawing.Size(1300, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "Ready."
    $form.Controls.Add($status)

    $script:ApiScanInventory = $null

    $btnScan.Add_Click({
        $output.Clear()
        $btnScan.Enabled = $false
        $status.Text = "Connecting..."
        try {
            Connect-PbiApi -TenantId $txtTenant.Text.Trim() `
                           -ClientId $txtClient.Text.Trim() `
                           -ClientSecret $txtSecret.Text.Trim() | Out-Null
            $output.AppendText("Connected: $script:PbiApiContext`r`n`r`n")

            $cb = {
                param($msg,$pct)
                $progress.Value = [Math]::Min(100,[Math]::Max(0,$pct))
                $status.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $raw = Start-PbiTenantScan -ProgressCallback $cb
            $inv = ConvertTo-PbiInventory -ScanResults $raw
            $script:ApiScanInventory = $inv

            $output.AppendText("TENANT INVENTORY`r`n")
            $output.AppendText(("=" * 78) + "`r`n")
            $output.AppendText(("Workspaces : {0}`r`n" -f @($inv.Workspaces).Count))
            $output.AppendText(("Datasets   : {0}`r`n" -f @($inv.Datasets).Count))
            $output.AppendText(("Reports    : {0}`r`n" -f @($inv.Reports).Count))
            $output.AppendText(("Dataflows  : {0}`r`n`r`n" -f @($inv.Dataflows).Count))

            if (@($LocalScan).Count -gt 0) {
                $cmp = Compare-GovernanceToService -LocalScan $LocalScan -Inventory $inv
                $output.AppendText("GOVERNANCE DRIFT REPORT`r`n")
                $output.AppendText(("=" * 78) + "`r`n")
                $output.AppendText(("Tenant datasets        : {0}`r`n" -f $cmp.ServiceDatasets))
                $output.AppendText(("Local governance models: {0}`r`n" -f $cmp.LocalModels))
                $output.AppendText(("Matched (governed)     : {0}  ({1}% coverage)`r`n`r`n" -f $cmp.MatchedCount, $cmp.CoveragePercent))

                $output.AppendText(("[!] In tenant but NOT in Governance folder ({0}):`r`n" -f @($cmp.MissingLocally).Count))
                foreach ($x in $cmp.MissingLocally) {
                    $output.AppendText(("    - {0} / {1}`r`n" -f $x.WorkspaceName, $x.DatasetName))
                }
                $output.AppendText(("`r`n[!] Local orphans (dataset gone from tenant) ({0}):`r`n" -f @($cmp.OrphanedLocal).Count))
                foreach ($x in $cmp.OrphanedLocal) {
                    $output.AppendText(("    - {0} / {1}`r`n" -f $x.WorkspaceName, $x.ModelName))
                }

                # Ownership & endorsement enrichment (from the live service).
                $output.AppendText("`r`nOWNERSHIP & ENDORSEMENT (governed models)`r`n")
                $output.AppendText(("=" * 78) + "`r`n")
                $output.AppendText(("Endorsement: {0}`r`n" -f (@($cmp.EndorsementSummary) -join "  |  ")))
                $output.AppendText(("Models with no owner ({0}):`r`n" -f @($cmp.UnownedModels).Count))
                foreach ($x in $cmp.UnownedModels) {
                    $output.AppendText(("    - {0} / {1}`r`n" -f $x.WorkspaceName, $x.ModelName))
                }
                $output.AppendText(("Not certified/promoted ({0}):`r`n" -f @($cmp.UncertifiedModels).Count))
                foreach ($x in $cmp.UncertifiedModels) {
                    $output.AppendText(("    - {0} / {1}  [{2}]`r`n" -f $x.WorkspaceName, $x.ModelName, $x.Endorsement))
                }
            }
            else {
                $output.AppendText("(Run a folder scan in the main window first to see the drift report.)`r`n")
            }

            $btnExport.Enabled = $true
            $status.Text = "Scan complete."
        }
        catch {
            $output.AppendText("`r`nERROR: $($_.Exception.Message)`r`n")
            $status.Text = "Failed."
        }
        finally {
            $btnScan.Enabled = $true
            $progress.Value = 0
        }
    })

    $btnExport.Add_Click({
        if (-not $script:ApiScanInventory) { return }
        $root = $GovernanceRoot
        if ([string]::IsNullOrEmpty($root)) {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $root = $fb.SelectedPath
        }
        $path = Export-PbiApiInventory -Inventory $script:ApiScanInventory -GovernanceRoot $root
        $status.Text = "Exported to $path"
        [System.Windows.Forms.MessageBox]::Show("Inventory exported:`n$path","Export complete") | Out-Null
    })

    $btnRefresh.Add_Click({
        if (@($LocalScan).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Run a folder scan in the main window first - refresh health is checked for the governed models.",
                "No models") | Out-Null
            return
        }
        $btnRefresh.Enabled = $false
        $output.Clear()
        $status.Text = "Connecting..."
        try {
            if (-not (Test-PbiApiConnection)) {
                Connect-PbiApi -TenantId $txtTenant.Text.Trim() `
                               -ClientId $txtClient.Text.Trim() `
                               -ClientSecret $txtSecret.Text.Trim() | Out-Null
            }
            $output.AppendText("REFRESH HEALTH (governed models)`r`n")
            $output.AppendText(("=" * 78) + "`r`n")
            $output.AppendText("Note: needs workspace access for the account/service principal.`r`n`r`n")

            $cb = {
                param($msg,$pct)
                $progress.Value = [Math]::Min(100,[Math]::Max(0,$pct))
                $status.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $health = Get-RefreshHealthReport -Models $LocalScan -ProgressCallback $cb
            $script:ApiRefreshHealth = $health

            foreach ($h in $health) {
                $flag = switch ($h.LastStatus) {
                    "Completed" { "  OK " }
                    "Failed"    { " FAIL" }
                    "NoAccess"  { " n/a " }
                    default     { "  ?  " }
                }
                $output.AppendText(("[{0}] {1} / {2}`r`n" -f $flag, $h.WorkspaceName, $h.ModelName))
                $output.AppendText(("        last: {0}  dur: {1} min  failures(5): {2}`r`n" -f `
                    $h.LastRefresh, $h.LastDurationMin, $h.FailuresInLast5))
                if ($h.LastStatus -eq "Failed" -and $h.LastError) {
                    $output.AppendText(("        error: {0}`r`n" -f $h.LastError))
                }
            }
            $failing = @($health | Where-Object { $_.LastStatus -eq "Failed" }).Count
            $status.Text = "Refresh health complete - $failing model(s) currently failing."
        }
        catch {
            $output.AppendText("`r`nERROR: $($_.Exception.Message)`r`n")
            $status.Text = "Failed."
        }
        finally {
            $btnRefresh.Enabled = $true
            $progress.Value = 0
        }
    })

    $btnLineage.Add_Click({
        if (-not $script:ApiScanInventory) {
            [System.Windows.Forms.MessageBox]::Show(
                "Run a tenant scan first - the lineage graph is built from the scan inventory.",
                "No inventory") | Out-Null
            return
        }
        if (Get-Command Show-LineageWindow -ErrorAction SilentlyContinue) {
            Show-LineageWindow -Inventory $script:ApiScanInventory `
                               -GovernanceRoot $GovernanceRoot -LocalScan $LocalScan
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Lineage-Graph.ps1 not loaded.`n`nEnsure it is in the Modules folder.",
                "Module missing") | Out-Null
        }
    })

    $btnUsage.Add_Click({
        if (Get-Command Show-UsageWindow -ErrorAction SilentlyContinue) {
            Show-UsageWindow -GovernanceRoot $GovernanceRoot -Inventory $script:ApiScanInventory
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Usage-Analytics.ps1 not loaded.`n`nEnsure it is in the Modules folder.",
                "Module missing") | Out-Null
        }
    })

    $btnAccess.Add_Click({
        if (Get-Command Show-AccessAuditWindow -ErrorAction SilentlyContinue) {
            Show-AccessAuditWindow -GovernanceRoot $GovernanceRoot
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "Access-Audit.ps1 not loaded.`n`nEnsure it is in the Modules folder.",
                "Module missing") | Out-Null
        }
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
