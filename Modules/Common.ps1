# Common.ps1
# Shared utility functions used across all modules

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Message Dialogs

function Show-ErrorMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message, 
        "Error", 
        [System.Windows.Forms.MessageBoxButtons]::OK, 
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-InfoMessage {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message, 
        "Information", 
        [System.Windows.Forms.MessageBoxButtons]::OK, 
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Show-ConfirmDialog {
    param([string]$Message)
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message, 
        "Confirm", 
        [System.Windows.Forms.MessageBoxButtons]::YesNo, 
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

#endregion

#region Folder Selection

function Select-GovernanceFolder {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select Governance root folder"
    $folderBrowser.ShowNewFolderButton = $false
    
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderBrowser.SelectedPath
    }
    return $null
}

#endregion

#region Progress Window

function Create-ProgressWindow {
    param([string]$Title = "Processing...")
    
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object System.Drawing.Size(400, 120)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    
    $script:progressLabel = New-Object System.Windows.Forms.Label
    $script:progressLabel.Location = New-Object System.Drawing.Point(10, 10)
    $script:progressLabel.Size = New-Object System.Drawing.Size(370, 20)
    $script:progressLabel.Text = "Processing..."
    $form.Controls.Add($script:progressLabel)
    
    $script:progressBar = New-Object System.Windows.Forms.ProgressBar
    $script:progressBar.Location = New-Object System.Drawing.Point(10, 40)
    $script:progressBar.Size = New-Object System.Drawing.Size(370, 30)
    $form.Controls.Add($script:progressBar)
    
    return $form
}

function Update-ProgressWindow {
    param(
        [string]$Text,
        [int]$Percent
    )
    
    if ($script:progressLabel) {
        $script:progressLabel.Text = $Text
        $script:progressLabel.Refresh()
    }
    if ($script:progressBar) {
        $script:progressBar.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
        $script:progressBar.Refresh()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

#endregion

#region PBI Tools

function Find-PbiTools {
    param([string]$GovernanceRoot)
    
    # Check in Governance/pbi-tools folder
    if (-not [string]::IsNullOrEmpty($GovernanceRoot)) {
        $localPbiTools = Join-Path $GovernanceRoot "pbi-tools\pbi-tools.exe"
        if (Test-Path $localPbiTools) {
            return $localPbiTools
        }
        
        $localPbiTools = Join-Path $GovernanceRoot "pbi-tools.exe"
        if (Test-Path $localPbiTools) {
            return $localPbiTools
        }
    }
    
    # Check in script directory
    $scriptDir = Split-Path -Parent $PSScriptRoot
    $localPbiTools = Join-Path $scriptDir "pbi-tools\pbi-tools.exe"
    if (Test-Path $localPbiTools) {
        return $localPbiTools
    }
    
    # Check global PATH
    try {
        $null = & pbi-tools info 2>&1
        return "pbi-tools"
    }
    catch {
        return $null
    }
}

#endregion

#region Utilities

function Get-Timestamp {
    return Get-Date -Format "yyyyMMdd_HHmmss"
}

function Ensure-OutputDirectory {
    param([string]$GovernanceRoot)
    
    $outputPath = Join-Path $GovernanceRoot "Analysis_Output"
    if (-not (Test-Path $outputPath)) {
        New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
    }
    return $outputPath
}

#endregion

# Functions are automatically available when dot-sourced
