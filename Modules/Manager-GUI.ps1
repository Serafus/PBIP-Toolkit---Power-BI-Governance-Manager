# Manager-GUI.ps1
# Main Manager Window - PBIP operations and extensions

# Global variables for the GUI
$script:GovernanceRootPath = ""
$script:ScanResults = @()
$script:PbiToolsPath = ""
$script:MainForm = $null
$script:ResultsTextBox = $null
$script:StatusLabel = $null

function Show-ManagerGUI {
    
    # Create main form
    $script:MainForm = New-Object System.Windows.Forms.Form
    $script:MainForm.Text = "PBIP Toolkit - Manager v1.0"
    $script:MainForm.Size = New-Object System.Drawing.Size(1300, 700)
    $script:MainForm.StartPosition = "CenterScreen"
    $script:MainForm.FormBorderStyle = "FixedDialog"
    $script:MainForm.MaximizeBox = $false
    
    # Governance folder label
    $lblGovernance = New-Object System.Windows.Forms.Label
    $lblGovernance.Location = New-Object System.Drawing.Point(10, 15)
    $lblGovernance.Size = New-Object System.Drawing.Size(120, 20)
    $lblGovernance.Text = "Governance Folder:"
    $script:MainForm.Controls.Add($lblGovernance)
    
    # Governance folder textbox
    $txtGovernance = New-Object System.Windows.Forms.TextBox
    $txtGovernance.Location = New-Object System.Drawing.Point(140, 12)
    $txtGovernance.Size = New-Object System.Drawing.Size(600, 20)
    $txtGovernance.ReadOnly = $true
    $script:MainForm.Controls.Add($txtGovernance)
    
    # Auto-fill with parent folder of script location
    try {
        $scriptLocation = Split-Path -Parent $script:ToolkitPath
        if (Test-Path $scriptLocation) {
            $script:GovernanceRootPath = $scriptLocation
            $txtGovernance.Text = $scriptLocation
            Write-Host "Auto-filled: $scriptLocation" -ForegroundColor Green
        }
    }
    catch {
        # Silent fail - user can browse manually
    }
    
    # Browse button
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Location = New-Object System.Drawing.Point(750, 10)
    $btnBrowse.Size = New-Object System.Drawing.Size(120, 25)
    $btnBrowse.Text = "Browse..."
    $btnBrowse.Add_Click({
        $folder = Select-GovernanceFolder
        if ($folder) {
            $script:GovernanceRootPath = $folder
            $txtGovernance.Text = $folder
        }
    })
    $script:MainForm.Controls.Add($btnBrowse)
    
    # Scan button
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Location = New-Object System.Drawing.Point(10, 45)
    $btnScan.Size = New-Object System.Drawing.Size(120, 30)
    $btnScan.Text = "Scan Folders"
    $btnScan.Add_Click({
        if ([string]::IsNullOrEmpty($script:GovernanceRootPath)) {
            Show-ErrorMessage "Please select a Governance folder first."
            return
        }
        
        # Find pbi-tools
        $script:PbiToolsPath = Find-PbiTools -GovernanceRoot $script:GovernanceRootPath
        if (-not $script:PbiToolsPath) {
            $message = @(
                "pbi-tools not found!",
                "",
                "Expected: $script:GovernanceRootPath\pbi-tools\pbi-tools.exe",
                "",
                "Install: dotnet tool install -g pbi-tools",
                "Download: https://github.com/pbi-tools/pbi-tools/releases"
            ) -join "`r`n"
            Show-ErrorMessage $message
            return
        }
        
        Update-StatusLabel "Using pbi-tools: $script:PbiToolsPath"
        Update-StatusLabel "Scanning folder structure..."
        
        $script:ScanResults = Scan-GovernanceStructure -RootPath $script:GovernanceRootPath
        Update-ScanResults
        Update-StatusLabel "Scan complete. Found $($script:ScanResults.Count) models."
    })
    $script:MainForm.Controls.Add($btnScan)
    
    # Generate All button
    $btnGenerateAll = New-Object System.Windows.Forms.Button
    $btnGenerateAll.Location = New-Object System.Drawing.Point(140, 45)
    $btnGenerateAll.Size = New-Object System.Drawing.Size(150, 30)
    $btnGenerateAll.Text = "Generate All (Replace)"
    $btnGenerateAll.Enabled = $false
    $btnGenerateAll.Add_Click({
        $result = Generate-AllPbip -ScanResults $script:ScanResults -PbiToolsPath $script:PbiToolsPath
        if ($result) {
            Update-ScanResults
        }
    })
    $script:MainForm.Controls.Add($btnGenerateAll)
    $script:btnGenerateAll = $btnGenerateAll
    
    # Generate Missing button
    $btnGenerateMissing = New-Object System.Windows.Forms.Button
    $btnGenerateMissing.Location = New-Object System.Drawing.Point(300, 45)
    $btnGenerateMissing.Size = New-Object System.Drawing.Size(150, 30)
    $btnGenerateMissing.Text = "Generate Missing Only"
    $btnGenerateMissing.Enabled = $false
    $btnGenerateMissing.Add_Click({
        $result = Generate-MissingPbip -ScanResults $script:ScanResults -PbiToolsPath $script:PbiToolsPath
        if ($result) {
            Update-ScanResults
        }
    })
    $script:MainForm.Controls.Add($btnGenerateMissing)
    $script:btnGenerateMissing = $btnGenerateMissing
    
    # Delete All button
    $btnDeleteAll = New-Object System.Windows.Forms.Button
    $btnDeleteAll.Location = New-Object System.Drawing.Point(460, 45)
    $btnDeleteAll.Size = New-Object System.Drawing.Size(150, 30)
    $btnDeleteAll.Text = "Delete All PBIP"
    $btnDeleteAll.Enabled = $false
    $btnDeleteAll.ForeColor = [System.Drawing.Color]::Red
    $btnDeleteAll.Add_Click({
        $result = Delete-AllPbip -ScanResults $script:ScanResults
        if ($result) {
            Update-ScanResults
        }
    })
    $script:MainForm.Controls.Add($btnDeleteAll)
    $script:btnDeleteAll = $btnDeleteAll
    
    # Analyze button (extension)
    $btnAnalyze = New-Object System.Windows.Forms.Button
    $btnAnalyze.Location = New-Object System.Drawing.Point(620, 45)
    $btnAnalyze.Size = New-Object System.Drawing.Size(120, 30)
    $btnAnalyze.Text = "Extraction Analysis"
    $btnAnalyze.Enabled = $false
    $btnAnalyze.BackColor = [System.Drawing.Color]::LightGreen
    $btnAnalyze.Add_Click({
        if (Get-Command Show-AnalyzerMenu -ErrorAction SilentlyContinue) {
            Show-AnalyzerMenu -GovernanceRoot $script:GovernanceRootPath
        }
        else {
            Show-InfoMessage "Analyzer-Menu.ps1 not loaded.`n`nPlease ensure all modules are in the Modules folder."
        }
    })
    $script:MainForm.Controls.Add($btnAnalyze)
    $script:btnAnalyze = $btnAnalyze
    
    # Statistics button
    $btnStats = New-Object System.Windows.Forms.Button
    $btnStats.Location = New-Object System.Drawing.Point(750, 45)
    $btnStats.Size = New-Object System.Drawing.Size(120, 30)
    $btnStats.Text = "Show Statistics"
    $btnStats.Enabled = $false
    $btnStats.BackColor = [System.Drawing.Color]::LightBlue
    $btnStats.Add_Click({
        if (Get-Command Show-StatisticsWindow -ErrorAction SilentlyContinue) {
            Show-StatisticsWindow -ScanResults $script:ScanResults
        }
        else {
            Show-InfoMessage "Manager-Stats.ps1 not loaded.`n`nPlease ensure all modules are in the Modules folder."
        }
    })
    $script:MainForm.Controls.Add($btnStats)
    $script:btnStats = $btnStats

    # API Scan button (Power BI REST / Scanner API)
    $btnApiScan = New-Object System.Windows.Forms.Button
    $btnApiScan.Location = New-Object System.Drawing.Point(880, 45)
    $btnApiScan.Size = New-Object System.Drawing.Size(120, 30)
    $btnApiScan.Text = "API Scan"
    $btnApiScan.BackColor = [System.Drawing.Color]::Khaki
    $btnApiScan.Add_Click({
        if (Get-Command Show-ApiScannerWindow -ErrorAction SilentlyContinue) {
            Show-ApiScannerWindow -LocalScan $script:ScanResults -GovernanceRoot $script:GovernanceRootPath
        }
        else {
            Show-InfoMessage "API-Scanner.ps1 not loaded.`n`nPlease ensure all modules are in the Modules folder."
        }
    })
    $script:MainForm.Controls.Add($btnApiScan)
    $script:btnApiScan = $btnApiScan

    # Scan History button (drift over time)
    $btnHistory = New-Object System.Windows.Forms.Button
    $btnHistory.Location = New-Object System.Drawing.Point(1010, 45)
    $btnHistory.Size = New-Object System.Drawing.Size(120, 30)
    $btnHistory.Text = "Scan History"
    $btnHistory.BackColor = [System.Drawing.Color]::Thistle
    $btnHistory.Add_Click({
        if ([string]::IsNullOrEmpty($script:GovernanceRootPath)) {
            Show-ErrorMessage "Please select a Governance folder first."
            return
        }
        if (Get-Command Show-ScanHistoryWindow -ErrorAction SilentlyContinue) {
            Show-ScanHistoryWindow -GovernanceRoot $script:GovernanceRootPath -CurrentScan $script:ScanResults
        }
        else {
            Show-InfoMessage "Scan-History.ps1 not loaded.`n`nPlease ensure all modules are in the Modules folder."
        }
    })
    $script:MainForm.Controls.Add($btnHistory)
    $script:btnHistory = $btnHistory

    # API Operations button (bulk access grant + TMDL download)
    $btnApiOps = New-Object System.Windows.Forms.Button
    $btnApiOps.Location = New-Object System.Drawing.Point(1140, 45)
    $btnApiOps.Size = New-Object System.Drawing.Size(140, 30)
    $btnApiOps.Text = "API Operations"
    $btnApiOps.BackColor = [System.Drawing.Color]::Khaki
    $btnApiOps.Add_Click({
        if (Get-Command Show-ApiOperationsWindow -ErrorAction SilentlyContinue) {
            Show-ApiOperationsWindow -GovernanceRoot $script:GovernanceRootPath -Inventory $script:LastApiScan
        }
        else {
            Show-InfoMessage "API-Operations.ps1 not loaded.`n`nPlease ensure all modules are in the Modules folder."
        }
    })
    $script:MainForm.Controls.Add($btnApiOps)
    $script:btnApiOps = $btnApiOps

    # Results RichTextBox (supports hyperlinks)
    $script:ResultsTextBox = New-Object System.Windows.Forms.RichTextBox
    $script:ResultsTextBox.Location = New-Object System.Drawing.Point(10, 85)
    $script:ResultsTextBox.Size = New-Object System.Drawing.Size(1260, 540)
    $script:ResultsTextBox.ScrollBars = "Vertical"
    $script:ResultsTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:ResultsTextBox.ReadOnly = $true
    $script:ResultsTextBox.DetectUrls = $true
    $script:ResultsTextBox.Add_LinkClicked({
        param($sender, $e)
        Start-Process $e.LinkText
    })
    $script:MainForm.Controls.Add($script:ResultsTextBox)
    
    # Status label
    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Location = New-Object System.Drawing.Point(10, 635)
    $script:StatusLabel.Size = New-Object System.Drawing.Size(1260, 20)
    $script:StatusLabel.Text = "Ready. Select a Governance folder to begin."
    $script:MainForm.Controls.Add($script:StatusLabel)
    
    # Initialize display
    Update-ScanResults
    
    # Show form
    [void]$script:MainForm.ShowDialog()
}

function Update-ScanResults {
    $script:ResultsTextBox.Clear()
    
    if ($script:ScanResults.Count -eq 0) {
        $script:ResultsTextBox.AppendText("No models found. Select Governance folder and click 'Scan Folders'.`r`n")
        return
    }
    
    $totalModels = $script:ScanResults.Count
    $existingPbip = ($script:ScanResults | Where-Object { $_.PbipExists }).Count
    $missingPbip = $totalModels - $existingPbip
    
    $script:ResultsTextBox.AppendText(("=" * 80) + "`r`n")
    $script:ResultsTextBox.AppendText("SCAN SUMMARY`r`n")
    $script:ResultsTextBox.AppendText(("=" * 80) + "`r`n")
    $script:ResultsTextBox.AppendText("Governance Root: $script:GovernanceRootPath`r`n")
    $script:ResultsTextBox.AppendText("Total Models: $totalModels`r`n")
    $script:ResultsTextBox.AppendText("Existing PBIP: $existingPbip`r`n")
    $script:ResultsTextBox.AppendText("Missing PBIP: $missingPbip`r`n")
    $script:ResultsTextBox.AppendText(("=" * 80) + "`r`n`r`n")
    
    $script:ResultsTextBox.AppendText("DETAILED RESULTS:`r`n")
    $script:ResultsTextBox.AppendText(("-" * 80) + "`r`n")
    
    # Group results by workspace
    $workspaceGroups = $script:ScanResults | Group-Object -Property WorkspaceName | Sort-Object Name
    
    foreach ($wsGroup in $workspaceGroups) {
        $firstModel = $wsGroup.Group[0]
        
        # Workspace header with inline link
        if ($firstModel.WorkspaceId) {
            $wsUrl = "https://app.powerbi.com/groups/$($firstModel.WorkspaceId)/"
            $script:ResultsTextBox.AppendText("$($wsGroup.Name) $wsUrl ($($firstModel.WorkspaceId))`r`n")
        } else {
            $script:ResultsTextBox.AppendText("$($wsGroup.Name)`r`n")
        }
        
        # Models under this workspace
        foreach ($result in $wsGroup.Group | Sort-Object ModelName) {
            $status = if ($result.PbipExists) { "[EXISTS]" } else { "[MISSING]" }
            
            # Model line with inline link and compact stats
            $modelLine = "  $status $($result.ModelName) "
            
            if ($result.DatasetId -and $result.WorkspaceId) {
                $modelUrl = "https://app.powerbi.com/groups/$($result.WorkspaceId)/datasets/$($result.DatasetId)/details"
                $modelLine += "$modelUrl "
            }
            
            $modelLine += "($($result.DatasetId))"
            $modelLine += " | PBIX: $($result.PbixSizeMB) MB"
            
            if ($result.HasReports) {
                $modelLine += " | Reports: $($result.ReportCount)"
            }
            
            if ($result.PbipExists) {
                $modelLine += " | PBIP: $($result.PbipFolderName)"
            }
            
            $script:ResultsTextBox.AppendText("$modelLine`r`n")
        }
        
        $script:ResultsTextBox.AppendText("`r`n")
    }
    
    # Update button states
    $script:btnGenerateAll.Enabled = $totalModels -gt 0
    $script:btnGenerateMissing.Enabled = $missingPbip -gt 0
    $script:btnDeleteAll.Enabled = $existingPbip -gt 0
    $script:btnAnalyze.Enabled = $existingPbip -gt 0
    $script:btnStats.Enabled = $totalModels -gt 0
}

function Update-StatusLabel {
    param([string]$Status)
    $script:StatusLabel.Text = $Status
    $script:StatusLabel.Refresh()
}

# Functions are automatically available when dot-sourced
