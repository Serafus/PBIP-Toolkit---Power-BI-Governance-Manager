# Usage-Analytics.ps1
# Pulls Power BI activity (audit) events from the Admin API and turns them into
# adoption metrics: views, distinct users and last-access per report and
# dataset, and - cross-referenced with the tenant inventory - a list of
# artifacts with no usage at all (retirement candidates).
#
# Depends on Connect-PbiApi / Invoke-PbiRestApi / Test-PbiApiConnection from
# API-Scanner.ps1, so this module must load after it.
#
# API: GET admin/activityevents - one UTC day per request, paged by a
# continuation token; roughly the last 30 days are retained by the service.
# Needs Tenant.Read.All (admin user, or a service principal allowed to use
# read-only admin APIs).

#region Activity event retrieval

function Get-PbiActivityEvents {
    <#
    .SYNOPSIS
        Returns Power BI activity events for the last N complete days.
    .PARAMETER Days
        How many days back to pull (1-30). Today is excluded - its day is
        not yet complete.
    #>
    param(
        [ValidateRange(1, 30)][int]$Days = 30,
        [scriptblock]$ProgressCallback
    )
    if (-not (Test-PbiApiConnection)) {
        throw "Not connected to the Power BI API. Run Connect-PbiApi first."
    }

    $events = @()
    $today  = (Get-Date).Date
    for ($d = 1; $d -le $Days; $d++) {
        $day   = $today.AddDays(-$d)
        $start = $day.ToString("yyyy-MM-ddT00:00:00")
        $end   = $day.ToString("yyyy-MM-ddT23:59:59")
        if ($ProgressCallback) {
            & $ProgressCallback ("Activity events: $($day.ToString('yyyy-MM-dd'))") ([int](($d / $Days) * 100))
        }

        $path = "admin/activityevents?startDateTime='$start'&endDateTime='$end'"
        $more = $true
        while ($more) {
            $resp = Invoke-PbiRestApi -Path $path
            foreach ($e in @($resp.activityEventEntities)) {
                $events += [PSCustomObject]@{
                    Date          = $e.CreationTime
                    Activity      = $e.Activity
                    UserId        = $e.UserId
                    WorkspaceName = $e.WorkSpaceName
                    WorkspaceId   = $e.WorkspaceId
                    ReportName    = $e.ReportName
                    ReportId      = $e.ReportId
                    ReportType    = $e.ReportType
                    DatasetName   = $e.DatasetName
                    DatasetId     = $e.DatasetId
                }
            }
            if ($resp.continuationToken -and $resp.continuationUri) {
                $path = $resp.continuationUri
            } else {
                $more = $false
            }
        }
    }
    return @($events)
}

#endregion

#region Aggregation

function Get-UsageSummary {
    <#
    .SYNOPSIS
        Aggregates raw activity events into adoption metrics. A "view" is any
        activity whose name starts with "View" (ViewReport, ViewDashboard...).
    .PARAMETER Inventory
        Optional ConvertTo-PbiInventory output. When supplied, reports and
        datasets present in the tenant but absent from the events are reported
        as unused (retirement candidates).
    #>
    param(
        [Parameter(Mandatory)]$Events,
        $Inventory = $null
    )
    $views = @($Events | Where-Object { $_.Activity -like "View*" })

    # Per-report adoption.
    $reportUsage = @()
    foreach ($g in ($views | Where-Object { $_.ReportId } | Group-Object ReportId)) {
        $first = $g.Group[0]
        $reportUsage += [PSCustomObject]@{
            ReportName    = $first.ReportName
            WorkspaceName = $first.WorkspaceName
            ReportId      = $g.Name
            Views         = $g.Count
            DistinctUsers = @($g.Group | Select-Object -ExpandProperty UserId -Unique).Count
            LastAccess    = (@($g.Group.Date) | Sort-Object | Select-Object -Last 1)
        }
    }
    $reportUsage = @($reportUsage | Sort-Object Views -Descending)

    # Per-dataset adoption.
    $datasetUsage = @()
    foreach ($g in ($views | Where-Object { $_.DatasetId } | Group-Object DatasetId)) {
        $first = $g.Group[0]
        $datasetUsage += [PSCustomObject]@{
            DatasetName   = $first.DatasetName
            WorkspaceName = $first.WorkspaceName
            DatasetId     = $g.Name
            Views         = $g.Count
            DistinctUsers = @($g.Group | Select-Object -ExpandProperty UserId -Unique).Count
            LastAccess    = (@($g.Group.Date) | Sort-Object | Select-Object -Last 1)
        }
    }
    $datasetUsage = @($datasetUsage | Sort-Object Views -Descending)

    # Top users and activity-type breakdown.
    $topUsers = @($views | Group-Object UserId |
        ForEach-Object { [PSCustomObject]@{ User = $_.Name; Views = $_.Count } } |
        Sort-Object Views -Descending | Select-Object -First 15)
    $byActivity = @($Events | Group-Object Activity |
        ForEach-Object { [PSCustomObject]@{ Activity = $_.Name; Count = $_.Count } } |
        Sort-Object Count -Descending)

    # Unused artifacts (need an inventory to know what exists).
    $unusedReports = @()
    $unusedDatasets = @()
    if ($Inventory) {
        $viewedReports  = @{}
        foreach ($r in $reportUsage)  { if ($r.ReportId)  { $viewedReports[$r.ReportId.ToLower()]  = $true } }
        $viewedDatasets = @{}
        foreach ($d in $datasetUsage) { if ($d.DatasetId) { $viewedDatasets[$d.DatasetId.ToLower()] = $true } }

        $unusedReports = @(@($Inventory.Reports) | Where-Object {
            $_.ReportId -and -not $viewedReports.ContainsKey($_.ReportId.ToLower())
        } | ForEach-Object { [PSCustomObject]@{ ReportName = $_.ReportName; WorkspaceName = $_.WorkspaceName } })

        $unusedDatasets = @(@($Inventory.Datasets) | Where-Object {
            $_.DatasetId -and -not $viewedDatasets.ContainsKey($_.DatasetId.ToLower())
        } | ForEach-Object { [PSCustomObject]@{ DatasetName = $_.DatasetName; WorkspaceName = $_.WorkspaceName } })
    }

    return [PSCustomObject]@{
        EventCount       = @($Events).Count
        ViewCount        = $views.Count
        DistinctUsers    = @($views | Select-Object -ExpandProperty UserId -Unique).Count
        ReportUsage      = $reportUsage
        DatasetUsage     = $datasetUsage
        TopUsers         = $topUsers
        ActivityBreakdown= $byActivity
        UnusedReports    = $unusedReports
        UnusedDatasets   = $unusedDatasets
    }
}

#endregion

#region Export

function Export-UsageReport {
    <#
    .SYNOPSIS
        Writes the usage summary to CSVs and a markdown report under
        <GovernanceRoot>\Analysis_Output.
    #>
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $out = Join-Path $GovernanceRoot "Analysis_Output"
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    if (@($Summary.ReportUsage).Count -gt 0) {
        $Summary.ReportUsage | Export-Csv -Path (Join-Path $out "Usage_Reports_$ts.csv") -NoTypeInformation -Encoding UTF8
    }
    if (@($Summary.DatasetUsage).Count -gt 0) {
        $Summary.DatasetUsage | Export-Csv -Path (Join-Path $out "Usage_Datasets_$ts.csv") -NoTypeInformation -Encoding UTF8
    }

    $md = Join-Path $out "Usage_$ts.md"
    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"
    [void]$sb.Append("# Power BI Usage & Adoption$nl$nl")
    [void]$sb.Append("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')$nl")
    [void]$sb.Append("Events: $($Summary.EventCount)  |  Views: $($Summary.ViewCount)  |  Distinct users: $($Summary.DistinctUsers)$nl$nl")

    [void]$sb.Append("## Most-viewed reports$nl$nl")
    foreach ($r in (@($Summary.ReportUsage) | Select-Object -First 15)) {
        [void]$sb.Append("- $($r.ReportName) ($($r.WorkspaceName)) - $($r.Views) views, $($r.DistinctUsers) users$nl")
    }
    [void]$sb.Append($nl + "## Unused reports (retirement candidates)$nl$nl")
    if (@($Summary.UnusedReports).Count -eq 0) {
        [void]$sb.Append("_None, or no inventory supplied._$nl")
    } else {
        foreach ($r in $Summary.UnusedReports) { [void]$sb.Append("- $($r.ReportName) ($($r.WorkspaceName))$nl") }
    }
    [void]$sb.Append($nl + "## Unused datasets (retirement candidates)$nl$nl")
    if (@($Summary.UnusedDatasets).Count -eq 0) {
        [void]$sb.Append("_None, or no inventory supplied._$nl")
    } else {
        foreach ($d in $Summary.UnusedDatasets) { [void]$sb.Append("- $($d.DatasetName) ($($d.WorkspaceName))$nl") }
    }
    $sb.ToString() | Set-Content -Path $md -Encoding UTF8

    Write-Host "Usage report written to: $out" -ForegroundColor Green
    return $md
}

#endregion

#region GUI

function Show-UsageWindow {
    <#
    .SYNOPSIS
        Window to pull activity events and view adoption metrics.
    .PARAMETER Inventory
        Optional inventory (from a prior API scan) - enables the unused-artifact
        lists.
    #>
    param(
        [string]$GovernanceRoot = "",
        $Inventory = $null
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Usage & Adoption"
    $form.Size = New-Object System.Drawing.Size(900, 640)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "Authentication (blank = interactive admin sign-in)"
    $grp.Location = New-Object System.Drawing.Point(12, 10)
    $grp.Size = New-Object System.Drawing.Size(870, 78)
    $form.Controls.Add($grp)

    $mkL = { param($t,$x,$y) $l=New-Object System.Windows.Forms.Label
        $l.Text=$t; $l.Location=New-Object System.Drawing.Point($x,$y)
        $l.Size=New-Object System.Drawing.Size(86,20); $grp.Controls.Add($l) }
    $mkB = { param($x,$y,$w,$pwd) $b=New-Object System.Windows.Forms.TextBox
        $b.Location=New-Object System.Drawing.Point($x,$y)
        $b.Size=New-Object System.Drawing.Size($w,20)
        if($pwd){$b.UseSystemPasswordChar=$true}; $grp.Controls.Add($b); $b }
    & $mkL "Tenant ID:" 10 22  | Out-Null; $txtTenant = & $mkB 100 20 230 $false
    & $mkL "Client ID:" 345 22 | Out-Null; $txtClient = & $mkB 435 20 230 $false
    & $mkL "Secret:" 10 48     | Out-Null; $txtSecret = & $mkB 100 46 230 $true

    $lblDays = New-Object System.Windows.Forms.Label
    $lblDays.Location = New-Object System.Drawing.Point(680, 22)
    $lblDays.Size = New-Object System.Drawing.Size(40, 20)
    $lblDays.Text = "Days:"
    $grp.Controls.Add($lblDays)
    $numDays = New-Object System.Windows.Forms.NumericUpDown
    $numDays.Location = New-Object System.Drawing.Point(722, 20)
    $numDays.Size = New-Object System.Drawing.Size(60, 20)
    $numDays.Minimum = 1; $numDays.Maximum = 30; $numDays.Value = 30
    $grp.Controls.Add($numDays)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Location = New-Object System.Drawing.Point(12, 96)
    $btnRun.Size = New-Object System.Drawing.Size(160, 30)
    $btnRun.Text = "Pull Usage"
    $btnRun.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnRun)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Location = New-Object System.Drawing.Point(182, 96)
    $btnExport.Size = New-Object System.Drawing.Size(150, 30)
    $btnExport.Text = "Export Report"
    $btnExport.Enabled = $false
    $form.Controls.Add($btnExport)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(342, 100)
    $progress.Size = New-Object System.Drawing.Size(540, 22)
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 134)
    $output.Size = New-Object System.Drawing.Size(870, 420)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 562)
    $status.Size = New-Object System.Drawing.Size(870, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "Ready."
    $form.Controls.Add($status)

    $script:UsageSummary = $null

    $btnRun.Add_Click({
        $output.Clear()
        $btnRun.Enabled = $false
        $status.Text = "Connecting..."
        try {
            if (-not (Test-PbiApiConnection)) {
                Connect-PbiApi -TenantId $txtTenant.Text.Trim() `
                               -ClientId $txtClient.Text.Trim() `
                               -ClientSecret $txtSecret.Text.Trim() | Out-Null
            }
            $cb = {
                param($msg,$pct)
                $progress.Value = [Math]::Min(100,[Math]::Max(0,$pct))
                $status.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $events  = Get-PbiActivityEvents -Days ([int]$numDays.Value) -ProgressCallback $cb
            $summary = Get-UsageSummary -Events $events -Inventory $Inventory
            $script:UsageSummary = $summary

            $output.AppendText("USAGE & ADOPTION  (last $([int]$numDays.Value) days)`r`n")
            $output.AppendText(("=" * 80) + "`r`n")
            $output.AppendText(("Events: {0}   Views: {1}   Distinct users: {2}`r`n`r`n" -f `
                $summary.EventCount, $summary.ViewCount, $summary.DistinctUsers))

            $output.AppendText("MOST-VIEWED REPORTS`r`n")
            foreach ($r in (@($summary.ReportUsage) | Select-Object -First 15)) {
                $output.AppendText(("  {0,5} views  {1,3} users   {2}  ({3})`r`n" -f `
                    $r.Views, $r.DistinctUsers, $r.ReportName, $r.WorkspaceName))
            }
            $output.AppendText(("`r`nUNUSED REPORTS - retirement candidates ({0})`r`n" -f @($summary.UnusedReports).Count))
            foreach ($r in $summary.UnusedReports) {
                $output.AppendText(("  - {0}  ({1})`r`n" -f $r.ReportName, $r.WorkspaceName))
            }
            $output.AppendText(("`r`nUNUSED DATASETS - retirement candidates ({0})`r`n" -f @($summary.UnusedDatasets).Count))
            foreach ($d in $summary.UnusedDatasets) {
                $output.AppendText(("  - {0}  ({1})`r`n" -f $d.DatasetName, $d.WorkspaceName))
            }
            if (-not $Inventory) {
                $output.AppendText("`r`n(Run an API tenant scan first to populate the unused-artifact lists.)`r`n")
            }
            $output.AppendText("`r`nTOP USERS`r`n")
            foreach ($u in (@($summary.TopUsers) | Select-Object -First 10)) {
                $output.AppendText(("  {0,5}  {1}`r`n" -f $u.Views, $u.User))
            }

            $btnExport.Enabled = $true
            $status.Text = "Usage pulled."
        }
        catch {
            $output.AppendText("`r`nERROR: $($_.Exception.Message)`r`n")
            $status.Text = "Failed."
        }
        finally {
            $btnRun.Enabled = $true
            $progress.Value = 0
        }
    })

    $btnExport.Add_Click({
        if (-not $script:UsageSummary) { return }
        $root = $GovernanceRoot
        if ([string]::IsNullOrEmpty($root)) {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $root = $fb.SelectedPath
        }
        $path = Export-UsageReport -Summary $script:UsageSummary -GovernanceRoot $root
        $status.Text = "Exported: $path"
        [System.Windows.Forms.MessageBox]::Show("Usage report written:`n$path","Export complete") | Out-Null
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
