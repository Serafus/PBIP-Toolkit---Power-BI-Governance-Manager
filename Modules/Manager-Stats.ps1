# Manager-Stats.ps1
# Statistics calculations for PBIP scan results

function Get-ScanStatistics {
    param([array]$ScanResults)
    
    if ($ScanResults.Count -eq 0) {
        return $null
    }
    
    $stats = @{
        TotalModels = $ScanResults.Count
        ExistingPBIP = ($ScanResults | Where-Object { $_.PbipExists }).Count
        MissingPBIP = ($ScanResults | Where-Object { -not $_.PbipExists }).Count
        TotalWorkspaces = ($ScanResults | Select-Object -ExpandProperty WorkspaceName -Unique).Count
        TotalSemanticModels = ($ScanResults | Select-Object -ExpandProperty ModelName -Unique).Count
        TotalPbixSizeMB = [math]::Round(($ScanResults | Measure-Object -Property PbixSizeMB -Sum).Sum, 2)
        AveragePbixSizeMB = [math]::Round(($ScanResults | Measure-Object -Property PbixSizeMB -Average).Average, 2)
        LargestModel = ($ScanResults | Sort-Object -Property PbixSizeMB -Descending | Select-Object -First 1)
        SmallestModel = ($ScanResults | Sort-Object -Property PbixSizeMB | Select-Object -First 1)
    }
    
    # Workspace breakdown
    $stats.WorkspaceBreakdown = $ScanResults | 
        Group-Object -Property WorkspaceName | 
        ForEach-Object {
            [PSCustomObject]@{
                Workspace = $_.Name
                ModelCount = $_.Count
                ExistingPBIP = ($_.Group | Where-Object { $_.PbipExists }).Count
                MissingPBIP = ($_.Group | Where-Object { -not $_.PbipExists }).Count
            }
        } | 
        Sort-Object -Property ModelCount -Descending
    
    return $stats
}

function Get-StatisticsSummary {
    param([hashtable]$Stats)
    
    if ($null -eq $Stats) {
        return "No statistics available. Please scan folders first."
    }
    
    $summary = @"
STATISTICS SUMMARY
$("=" * 80)

Overview:
  Total Models: $($Stats.TotalModels)
  Unique Workspaces: $($Stats.TotalWorkspaces)
  Unique Semantic Models: $($Stats.TotalSemanticModels)

PBIP Status:
  Existing PBIP Folders: $($Stats.ExistingPBIP)
  Missing PBIP Folders: $($Stats.MissingPBIP)
  Coverage: $([math]::Round(($Stats.ExistingPBIP / $Stats.TotalModels) * 100, 1))%

Storage:
  Total PBIX Size: $($Stats.TotalPbixSizeMB) MB
  Average Model Size: $($Stats.AveragePbixSizeMB) MB
  Largest Model: $($Stats.LargestModel.ModelName) ($($Stats.LargestModel.PbixSizeMB) MB)
  Smallest Model: $($Stats.SmallestModel.ModelName) ($($Stats.SmallestModel.PbixSizeMB) MB)

Workspace Breakdown:
$("-" * 80)
"@

    # Add workspace details
    foreach ($ws in $Stats.WorkspaceBreakdown) {
        $summary += "`n  $($ws.Workspace): $($ws.ModelCount) models ($($ws.ExistingPBIP) PBIP, $($ws.MissingPBIP) missing)"
    }
    
    $summary += "`n$("=" * 80)"
    
    return $summary
}

function Show-StatisticsWindow {
    param([array]$ScanResults)
    
    $stats = Get-ScanStatistics -ScanResults $ScanResults
    
    if ($null -eq $stats) {
        Show-InfoMessage "No statistics available. Please scan folders first."
        return
    }
    
    # Create statistics window
    $statsForm = New-Object System.Windows.Forms.Form
    $statsForm.Text = "PBIP Statistics"
    $statsForm.Size = New-Object System.Drawing.Size(800, 700)
    $statsForm.StartPosition = "CenterScreen"
    $statsForm.FormBorderStyle = "Sizable"
    
    # Static statistics text box (top section)
    $staticStats = New-Object System.Windows.Forms.TextBox
    $staticStats.Location = New-Object System.Drawing.Point(10, 10)
    $staticStats.Size = New-Object System.Drawing.Size(765, 220)
    $staticStats.Multiline = $true
    $staticStats.ScrollBars = "Vertical"
    $staticStats.Font = New-Object System.Drawing.Font("Consolas", 9)
    $staticStats.ReadOnly = $true
    
    $staticText = @"
STATISTICS SUMMARY
$("=" * 80)

Overview:
  Total Models: $($stats.TotalModels)
  Unique Workspaces: $($stats.TotalWorkspaces)
  PBIP Status: Existing: $($stats.ExistingPBIP) | Missing: $($stats.MissingPBIP) | Coverage: $([math]::Round(($stats.ExistingPBIP / $stats.TotalModels) * 100, 1))%

Storage:
  Total PBIX Size: $($stats.TotalPbixSizeMB) MB
  Average Model Size: $($stats.AveragePbixSizeMB) MB
  Largest Model: $($stats.LargestModel.ModelName) ($($stats.LargestModel.PbixSizeMB) MB)
  Smallest Model: $($stats.SmallestModel.ModelName) ($($stats.SmallestModel.PbixSizeMB) MB)

Workspace Breakdown:
$("-" * 80)
"@
    
    $staticStats.Text = $staticText
    $statsForm.Controls.Add($staticStats)
    
    # Interactive workspace RichTextBox with hyperlinks
    $script:workspaceBox = New-Object System.Windows.Forms.RichTextBox
    $script:workspaceBox.Location = New-Object System.Drawing.Point(10, 240)
    $script:workspaceBox.Size = New-Object System.Drawing.Size(765, 350)
    $script:workspaceBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:workspaceBox.ReadOnly = $true
    $script:workspaceBox.DetectUrls = $true
    $script:workspaceBox.Add_LinkClicked({
        param($sender, $e)
        Start-Process $e.LinkText
    })
    $statsForm.Controls.Add($script:workspaceBox)
    
    # Track expanded workspaces
    $script:expandedWorkspaces = @{}
    
    # Initial collapsed view
    Update-WorkspaceView -Stats $stats -ScanResults $ScanResults
    
    # Handle clicks on expand/collapse icons
    $script:workspaceBox.Add_MouseClick({
        param($sender, $e)
        
        # Get clicked line
        $index = $script:workspaceBox.GetCharIndexFromPosition($e.Location)
        $line = $script:workspaceBox.GetLineFromCharIndex($index)
        $lineText = $script:workspaceBox.Lines[$line]
        
        # Check if clicked on â–¶ or â–¼
        if ($lineText -match '^[â–¶â–¼]\s+(.+?)\s+\(') {
            $wsName = $Matches[1]
            
            # Toggle expand state
            if ($script:expandedWorkspaces.ContainsKey($wsName)) {
                $script:expandedWorkspaces[$wsName] = -not $script:expandedWorkspaces[$wsName]
            } else {
                $script:expandedWorkspaces[$wsName] = $true
            }
            
            Update-WorkspaceView -Stats $stats -ScanResults $ScanResults
        }
    })
    
    # Buttons
    $btnExpandAll = New-Object System.Windows.Forms.Button
    $btnExpandAll.Location = New-Object System.Drawing.Point(10, 600)
    $btnExpandAll.Size = New-Object System.Drawing.Size(100, 30)
    $btnExpandAll.Text = "Expand All"
    $btnExpandAll.Add_Click({
        foreach ($ws in $stats.WorkspaceBreakdown) {
            $script:expandedWorkspaces[$ws.Workspace] = $true
        }
        Update-WorkspaceView -Stats $stats -ScanResults $ScanResults
    })
    $statsForm.Controls.Add($btnExpandAll)
    
    $btnCollapseAll = New-Object System.Windows.Forms.Button
    $btnCollapseAll.Location = New-Object System.Drawing.Point(120, 600)
    $btnCollapseAll.Size = New-Object System.Drawing.Size(100, 30)
    $btnCollapseAll.Text = "Collapse All"
    $btnCollapseAll.Add_Click({
        $script:expandedWorkspaces = @{}
        Update-WorkspaceView -Stats $stats -ScanResults $ScanResults
    })
    $statsForm.Controls.Add($btnCollapseAll)
    
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Location = New-Object System.Drawing.Point(675, 600)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.Text = "Close"
    $btnClose.Add_Click({ $statsForm.Close() })
    $statsForm.Controls.Add($btnClose)
    
    [void]$statsForm.ShowDialog()
}

function Update-WorkspaceView {
    param(
        [hashtable]$Stats,
        [array]$ScanResults
    )
    
    $script:workspaceBox.Clear()
    
    foreach ($ws in $Stats.WorkspaceBreakdown) {
        $wsName = $ws.Workspace
        $isExpanded = $script:expandedWorkspaces[$wsName] -eq $true
        $icon = if ($isExpanded) { "â–¼" } else { "â–¶" }
        
        # Get workspace ID from first model in this workspace
        $firstModel = $ScanResults | Where-Object { $_.WorkspaceName -eq $wsName } | Select-Object -First 1
        
        # Workspace line
        $wsLine = "$icon $wsName ($($ws.ModelCount) models | $($ws.ExistingPBIP) PBIP | $($ws.MissingPBIP) missing)`r`n"
        
        # If workspace has ID, make workspace name a hyperlink
        if ($firstModel.WorkspaceId) {
            $wsUrl = "https://app.powerbi.com/groups/$($firstModel.WorkspaceId)/"
            # Replace workspace name with URL in the line
            $wsLine = "$icon $wsUrl ($($ws.ModelCount) models | $($ws.ExistingPBIP) PBIP | $($ws.MissingPBIP) missing)`r`n"
        }
        
        $script:workspaceBox.AppendText($wsLine)
        
        # If expanded, show models
        if ($isExpanded) {
            $wsModels = $ScanResults | Where-Object { $_.WorkspaceName -eq $wsName } | Sort-Object ModelName
            
            foreach ($model in $wsModels) {
                $status = if ($model.PbipExists) { "[EXISTS]" } else { "[MISSING]" }
                $modelLine = "    $status $($model.ModelName) ($($model.PbixSizeMB) MB)"
                
                if ($model.HasReports) {
                    $modelLine += " | Reports: $($model.ReportCount)"
                }
                
                $modelLine += "`r`n"
                
                # Add model line with hyperlink if dataset ID available
                if ($model.DatasetId -and $model.WorkspaceId) {
                    $modelUrl = "https://app.powerbi.com/groups/$($model.WorkspaceId)/datasets/$($model.DatasetId)/details"
                    $modelLineWithUrl = "    $status $modelUrl ($($model.PbixSizeMB) MB)"
                    if ($model.HasReports) {
                        $modelLineWithUrl += " | Reports: $($model.ReportCount)"
                    }
                    $modelLineWithUrl += "`r`n"
                    $script:workspaceBox.AppendText($modelLineWithUrl)
                } else {
                    $script:workspaceBox.AppendText($modelLine)
                }
            }
            
            $script:workspaceBox.AppendText("`r`n")
        }
    }
}

# Functions are automatically available when dot-sourced
