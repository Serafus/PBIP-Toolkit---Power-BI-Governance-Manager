# Scan-History.ps1
# Persists folder-scan snapshots so governance drift can be tracked over time,
# not just observed in a single moment. Snapshots are small JSON files written
# to <GovernanceRoot>\Analysis_Output\History\, and any two of them (or a
# snapshot vs. the current scan) can be diffed: models added, models removed,
# size changes, and PBIP-coverage changes.

#region Snapshot model

function ConvertTo-SnapshotModel {
    # Reduces a Scan-GovernanceStructure result to the fields a snapshot keeps.
    param([Parameter(Mandatory)]$ScanResults)
    @($ScanResults | ForEach-Object {
        [PSCustomObject]@{
            WorkspaceName = $_.WorkspaceName
            ModelName     = $_.ModelName
            WorkspaceId   = $_.WorkspaceId
            DatasetId     = $_.DatasetId
            PbixSizeMB    = $_.PbixSizeMB
            PbipExists    = [bool]$_.PbipExists
        }
    })
}

function Get-ModelKey {
    # Stable identity for a model across snapshots: dataset id when known,
    # otherwise the workspace\model folder path.
    param($Model)
    if ($Model.DatasetId) { return "ds:" + $Model.DatasetId.ToLower() }
    return ("path:{0}\{1}" -f $Model.WorkspaceName, $Model.ModelName).ToLower()
}

#endregion

#region Save / load

function Save-ScanSnapshot {
    <#
    .SYNOPSIS
        Writes the current folder scan to a timestamped JSON snapshot.
    .PARAMETER ScanResults
        Output of Scan-GovernanceStructure.
    .PARAMETER GovernanceRoot
        Governance root - the History folder is created beneath Analysis_Output.
    #>
    param(
        [Parameter(Mandatory)]$ScanResults,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $models = ConvertTo-SnapshotModel -ScanResults $ScanResults
    if ($models.Count -eq 0) { throw "Nothing to snapshot - scan results are empty." }

    $histDir = Join-Path (Join-Path $GovernanceRoot "Analysis_Output") "History"
    if (-not (Test-Path $histDir)) { New-Item -ItemType Directory -Path $histDir -Force | Out-Null }

    $existing = @($models | Where-Object { $_.PbipExists }).Count
    $snapshot = [PSCustomObject]@{
        Timestamp      = (Get-Date).ToString("o")
        GovernanceRoot = $GovernanceRoot
        ModelCount     = $models.Count
        TotalSizeMB    = [math]::Round((@($models | Measure-Object -Property PbixSizeMB -Sum).Sum), 2)
        PbipCoverage   = if ($models.Count -gt 0) { [math]::Round(($existing / $models.Count) * 100, 1) } else { 0 }
        Models         = $models
    }
    $file = Join-Path $histDir ("snapshot_{0}.json" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8
    Write-Host "Snapshot saved: $file" -ForegroundColor Green
    return $file
}

function Get-ScanSnapshots {
    <#
    .SYNOPSIS
        Lists saved snapshots (newest first) with summary metadata.
    #>
    param([Parameter(Mandatory)][string]$GovernanceRoot)
    $histDir = Join-Path (Join-Path $GovernanceRoot "Analysis_Output") "History"
    if (-not (Test-Path $histDir)) { return @() }

    $list = foreach ($f in (Get-ChildItem -Path $histDir -Filter "snapshot_*.json" -File)) {
        try {
            $data = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            [PSCustomObject]@{
                Path         = $f.FullName
                FileName     = $f.Name
                Timestamp    = [datetime]$data.Timestamp
                ModelCount   = $data.ModelCount
                TotalSizeMB  = $data.TotalSizeMB
                PbipCoverage = $data.PbipCoverage
            }
        }
        catch {
            Write-Host "Skipping unreadable snapshot: $($f.Name)" -ForegroundColor Yellow
        }
    }
    return @($list | Sort-Object Timestamp -Descending)
}

function Get-SnapshotData {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

#endregion

#region Compare

function Compare-ScanSnapshots {
    <#
    .SYNOPSIS
        Diffs two snapshots (or snapshot-shaped objects). Reports models added,
        removed, resized, and changes in PBIP extraction status.
    .PARAMETER Older
        The earlier snapshot object (from Get-SnapshotData) - the baseline.
    .PARAMETER Newer
        The later snapshot object - the comparison point.
    .PARAMETER SizeThresholdMB
        Minimum absolute PBIX size change to report (default 1 MB).
    #>
    param(
        [Parameter(Mandatory)]$Older,
        [Parameter(Mandatory)]$Newer,
        [double]$SizeThresholdMB = 1.0
    )

    $oldByKey = @{}
    foreach ($m in @($Older.Models)) { $oldByKey[(Get-ModelKey $m)] = $m }
    $newByKey = @{}
    foreach ($m in @($Newer.Models)) { $newByKey[(Get-ModelKey $m)] = $m }

    $added = foreach ($k in $newByKey.Keys) {
        if (-not $oldByKey.ContainsKey($k)) {
            $m = $newByKey[$k]
            [PSCustomObject]@{ WorkspaceName=$m.WorkspaceName; ModelName=$m.ModelName; PbixSizeMB=$m.PbixSizeMB }
        }
    }
    $removed = foreach ($k in $oldByKey.Keys) {
        if (-not $newByKey.ContainsKey($k)) {
            $m = $oldByKey[$k]
            [PSCustomObject]@{ WorkspaceName=$m.WorkspaceName; ModelName=$m.ModelName; PbixSizeMB=$m.PbixSizeMB }
        }
    }
    $resized = foreach ($k in $newByKey.Keys) {
        if ($oldByKey.ContainsKey($k)) {
            $o = $oldByKey[$k]; $n = $newByKey[$k]
            $delta = [math]::Round($n.PbixSizeMB - $o.PbixSizeMB, 2)
            if ([math]::Abs($delta) -ge $SizeThresholdMB) {
                [PSCustomObject]@{
                    WorkspaceName = $n.WorkspaceName
                    ModelName     = $n.ModelName
                    OldSizeMB     = $o.PbixSizeMB
                    NewSizeMB     = $n.PbixSizeMB
                    DeltaMB       = $delta
                }
            }
        }
    }
    $pbipChanged = foreach ($k in $newByKey.Keys) {
        if ($oldByKey.ContainsKey($k)) {
            $o = $oldByKey[$k]; $n = $newByKey[$k]
            if ([bool]$o.PbipExists -ne [bool]$n.PbipExists) {
                [PSCustomObject]@{
                    WorkspaceName = $n.WorkspaceName
                    ModelName     = $n.ModelName
                    Change        = if ($n.PbipExists) { "PBIP added" } else { "PBIP removed" }
                }
            }
        }
    }

    return [PSCustomObject]@{
        OlderTimestamp = $Older.Timestamp
        NewerTimestamp = $Newer.Timestamp
        Added          = @($added)
        Removed        = @($removed)
        Resized        = @($resized)
        PbipChanged    = @($pbipChanged)
        ModelCountDelta = (@($Newer.Models).Count - @($Older.Models).Count)
        SizeDeltaMB     = [math]::Round(
                              (@($Newer.Models | Measure-Object PbixSizeMB -Sum).Sum) -
                              (@($Older.Models | Measure-Object PbixSizeMB -Sum).Sum), 2)
    }
}

function Format-SnapshotDiff {
    # Renders a Compare-ScanSnapshots result as readable text.
    param([Parameter(Mandatory)]$Diff)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("SNAPSHOT COMPARISON")
    [void]$sb.AppendLine("=" * 72)
    [void]$sb.AppendLine(("Baseline : {0}" -f $Diff.OlderTimestamp))
    [void]$sb.AppendLine(("Compared : {0}" -f $Diff.NewerTimestamp))
    [void]$sb.AppendLine(("Model count change : {0:+#;-#;0}" -f $Diff.ModelCountDelta))
    [void]$sb.AppendLine(("Total size change  : {0:+#.##;-#.##;0} MB" -f $Diff.SizeDeltaMB))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine(("Models added ({0}):" -f @($Diff.Added).Count))
    foreach ($x in $Diff.Added)   { [void]$sb.AppendLine(("  + {0} / {1}  ({2} MB)" -f $x.WorkspaceName,$x.ModelName,$x.PbixSizeMB)) }
    [void]$sb.AppendLine(("Models removed ({0}):" -f @($Diff.Removed).Count))
    foreach ($x in $Diff.Removed) { [void]$sb.AppendLine(("  - {0} / {1}  ({2} MB)" -f $x.WorkspaceName,$x.ModelName,$x.PbixSizeMB)) }
    [void]$sb.AppendLine(("Models resized ({0}):" -f @($Diff.Resized).Count))
    foreach ($x in $Diff.Resized) { [void]$sb.AppendLine(("  ~ {0} / {1}  {2} -> {3} MB  ({4:+#.##;-#.##;0})" -f $x.WorkspaceName,$x.ModelName,$x.OldSizeMB,$x.NewSizeMB,$x.DeltaMB)) }
    [void]$sb.AppendLine(("PBIP status changes ({0}):" -f @($Diff.PbipChanged).Count))
    foreach ($x in $Diff.PbipChanged) { [void]$sb.AppendLine(("  * {0} / {1}  {2}" -f $x.WorkspaceName,$x.ModelName,$x.Change)) }
    return $sb.ToString()
}

#endregion

#region GUI

function Show-ScanHistoryWindow {
    <#
    .SYNOPSIS
        Window to save snapshots and compare governance state over time.
    .PARAMETER GovernanceRoot
        Governance root path.
    .PARAMETER CurrentScan
        Current $script:ScanResults (optional) - enables "save" and
        "compare to current".
    #>
    param(
        [Parameter(Mandatory)][string]$GovernanceRoot,
        $CurrentScan = @()
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Scan History & Drift"
    $form.Size = New-Object System.Drawing.Size(820, 640)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(780, 20)
    $lbl.Text = "Save scan snapshots and diff them to see how the governed estate changes over time."
    $form.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(12, 38)
    $list.Size = New-Object System.Drawing.Size(780, 170)
    $list.SelectionMode = "MultiExtended"
    $list.Font = New-Object System.Drawing.Font("Consolas", 9)
    $list.Anchor = "Top,Left,Right"
    $form.Controls.Add($list)

    $script:HistorySnapshots = @()
    $reload = {
        $list.Items.Clear()
        $script:HistorySnapshots = @(Get-ScanSnapshots -GovernanceRoot $GovernanceRoot)
        foreach ($s in $script:HistorySnapshots) {
            $list.Items.Add(("{0}   models:{1,4}   size:{2,9} MB   PBIP:{3,5}%" -f `
                $s.Timestamp.ToString("yyyy-MM-dd HH:mm"), $s.ModelCount, $s.TotalSizeMB, $s.PbipCoverage)) | Out-Null
        }
        if ($script:HistorySnapshots.Count -eq 0) {
            $list.Items.Add("(no snapshots yet - click 'Save Current Snapshot')") | Out-Null
        }
    }
    & $reload

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 256)
    $output.Size = New-Object System.Drawing.Size(780, 300)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 566)
    $status.Size = New-Object System.Drawing.Size(780, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "$($script:HistorySnapshots.Count) snapshot(s)."
    $form.Controls.Add($status)

    # --- buttons -----------------------------------------------------------
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Location = New-Object System.Drawing.Point(12, 214)
    $btnSave.Size = New-Object System.Drawing.Size(170, 32)
    $btnSave.Text = "Save Current Snapshot"
    $btnSave.BackColor = [System.Drawing.Color]::LightGreen
    $btnSave.Enabled = (@($CurrentScan).Count -gt 0)
    $btnSave.Add_Click({
        try {
            $f = Save-ScanSnapshot -ScanResults $CurrentScan -GovernanceRoot $GovernanceRoot
            & $reload
            $status.Text = "Saved: $(Split-Path $f -Leaf)"
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed") | Out-Null
        }
    })
    $form.Controls.Add($btnSave)

    $btnCompare = New-Object System.Windows.Forms.Button
    $btnCompare.Location = New-Object System.Drawing.Point(192, 214)
    $btnCompare.Size = New-Object System.Drawing.Size(170, 32)
    $btnCompare.Text = "Compare Selected (2)"
    $btnCompare.Add_Click({
        $sel = @($list.SelectedIndices)
        if ($sel.Count -ne 2) {
            [System.Windows.Forms.MessageBox]::Show("Select exactly two snapshots to compare.", "Pick two") | Out-Null
            return
        }
        $a = $script:HistorySnapshots[$sel[0]]
        $b = $script:HistorySnapshots[$sel[1]]
        # Older as baseline regardless of click order.
        if ($a.Timestamp -gt $b.Timestamp) { $tmp = $a; $a = $b; $b = $tmp }
        $diff = Compare-ScanSnapshots -Older (Get-SnapshotData $a.Path) -Newer (Get-SnapshotData $b.Path)
        $output.Text = Format-SnapshotDiff -Diff $diff
        $status.Text = "Compared two snapshots."
    })
    $form.Controls.Add($btnCompare)

    $btnVsCurrent = New-Object System.Windows.Forms.Button
    $btnVsCurrent.Location = New-Object System.Drawing.Point(372, 214)
    $btnVsCurrent.Size = New-Object System.Drawing.Size(170, 32)
    $btnVsCurrent.Text = "Compare Selected to Current"
    $btnVsCurrent.Enabled = (@($CurrentScan).Count -gt 0)
    $btnVsCurrent.Add_Click({
        $sel = @($list.SelectedIndices)
        if ($sel.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show("Select one snapshot to compare against the current scan.", "Pick one") | Out-Null
            return
        }
        $base = $script:HistorySnapshots[$sel[0]]
        $current = [PSCustomObject]@{
            Timestamp = "current scan"
            Models    = (ConvertTo-SnapshotModel -ScanResults $CurrentScan)
        }
        $diff = Compare-ScanSnapshots -Older (Get-SnapshotData $base.Path) -Newer $current
        $output.Text = Format-SnapshotDiff -Diff $diff
        $status.Text = "Compared snapshot to current scan."
    })
    $form.Controls.Add($btnVsCurrent)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Location = New-Object System.Drawing.Point(552, 214)
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 32)
    $btnRefresh.Text = "Reload"
    $btnRefresh.Add_Click({ & $reload; $status.Text = "$($script:HistorySnapshots.Count) snapshot(s)." })
    $form.Controls.Add($btnRefresh)

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
