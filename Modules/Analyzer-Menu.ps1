# Analyzer-Menu.ps1
# Analysis submenu for PBIP extraction analysis

function Show-AnalyzerMenu {
    param([string]$GovernanceRoot)
    
    if ([string]::IsNullOrEmpty($GovernanceRoot)) {
        Show-ErrorMessage "Governance folder not set!"
        return
    }
    
    # Find all PBIP folders
    $pbipFolders = @(Get-ChildItem -Path $GovernanceRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^pbip_' })
    
    if ($pbipFolders.Count -eq 0) {
        Show-ErrorMessage "No PBIP folders found!`n`nPlease generate PBIP folders first."
        return
    }
    
    # Create analyzer window
    $analyzerForm = New-Object System.Windows.Forms.Form
    $analyzerForm.Text = "Extraction Analysis - Step by Step"
    $analyzerForm.Size = New-Object System.Drawing.Size(700, 550)
    $analyzerForm.StartPosition = "CenterScreen"
    $analyzerForm.FormBorderStyle = "FixedDialog"
    $analyzerForm.MaximizeBox = $false
    
    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size = New-Object System.Drawing.Size(650, 30)
    $titleLabel.Text = "PBIP Extraction Analysis"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $analyzerForm.Controls.Add($titleLabel)
    
    # Info label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Location = New-Object System.Drawing.Point(20, 60)
    $infoLabel.Size = New-Object System.Drawing.Size(650, 40)
    $infoLabel.Text = "Found $($pbipFolders.Count) PBIP folders`nSelect analysis steps to run:"
    $analyzerForm.Controls.Add($infoLabel)
    
    # Step 1 Button
    $btnStep1 = New-Object System.Windows.Forms.Button
    $btnStep1.Location = New-Object System.Drawing.Point(20, 120)
    $btnStep1.Size = New-Object System.Drawing.Size(650, 35)
    $btnStep1.Text = "Step 1a: Analyze model/model.tmdl (table and role references)"
    $btnStep1.BackColor = [System.Drawing.Color]::LightBlue
    $btnStep1.Add_Click({
        if (Get-Command Run-Step1Analysis -ErrorAction SilentlyContinue) {
            $btnStep1.Enabled = $false
            Run-Step1Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
            $btnStep1.Enabled = $true
        } else {
            Show-InfoMessage "Step1-Model.ps1 not loaded yet.`n`nNext module to create!"
        }
    })
    $analyzerForm.Controls.Add($btnStep1)
    
    # Step 2 Button
    $btnStep2 = New-Object System.Windows.Forms.Button
    $btnStep2.Location = New-Object System.Drawing.Point(20, 160)
    $btnStep2.Size = New-Object System.Drawing.Size(650, 35)
    $btnStep2.Text = "Step 1b: Analyze model/tables/*.tmdl (source types and M queries)"
    $btnStep2.BackColor = [System.Drawing.Color]::LightBlue
    $btnStep2.Add_Click({
        if (Get-Command Run-Step2Analysis -ErrorAction SilentlyContinue) {
            $btnStep2.Enabled = $false
            Run-Step2Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
            $btnStep2.Enabled = $true
        } else {
            Show-InfoMessage "Step2-Tables.ps1 not loaded yet.`n`nNext module to create!"
        }
    })
    $analyzerForm.Controls.Add($btnStep2)
    
    # Step 3 Button
    $btnStep3 = New-Object System.Windows.Forms.Button
    $btnStep3.Location = New-Object System.Drawing.Point(20, 200)
    $btnStep3.Size = New-Object System.Drawing.Size(650, 35)
    $btnStep3.Text = "Step 1c: Analyze model/roles/*.tmdl (RLS definitions and permissions)"
    $btnStep3.BackColor = [System.Drawing.Color]::LightBlue
    $btnStep3.Add_Click({
        if (Get-Command Run-Step3Analysis -ErrorAction SilentlyContinue) {
            $btnStep3.Enabled = $false
            Run-Step3Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
            $btnStep3.Enabled = $true
        } else {
            Show-InfoMessage "Step3-Roles.ps1 not loaded yet.`n`nNext module to create!"
        }
    })
    $analyzerForm.Controls.Add($btnStep3)
    
    # Step 4 Button
    $btnStep4 = New-Object System.Windows.Forms.Button
    $btnStep4.Location = New-Object System.Drawing.Point(20, 240)
    $btnStep4.Size = New-Object System.Drawing.Size(650, 35)
    $btnStep4.Text = "Step 1d: Analyze model/expressions/ (DAX measures and calculated columns)"
    $btnStep4.BackColor = [System.Drawing.Color]::LightBlue
    $btnStep4.Add_Click({
        if (Get-Command Run-Step4Analysis -ErrorAction SilentlyContinue) {
            $btnStep4.Enabled = $false
            Run-Step4Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
            $btnStep4.Enabled = $true
        } else {
            Show-InfoMessage "Step4-Expressions.ps1 not loaded yet.`n`nFuture module!"
        }
    })
    $analyzerForm.Controls.Add($btnStep4)
    
    # Best Practice Analysis Button
    $btnBP = New-Object System.Windows.Forms.Button
    $btnBP.Location = New-Object System.Drawing.Point(20, 285)
    $btnBP.Size = New-Object System.Drawing.Size(315, 40)
    $btnBP.Text = "Best Practice Analysis"
    $btnBP.BackColor = [System.Drawing.Color]::Khaki
    $btnBP.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnBP.Add_Click({
        if (Get-Command Show-BestPracticeWindow -ErrorAction SilentlyContinue) {
            Show-BestPracticeWindow -GovernanceRoot $GovernanceRoot
        }
        else {
            Show-InfoMessage "BestPractice-Analyzer.ps1 not loaded.`n`nEnsure it is in the Modules folder."
        }
    })
    $analyzerForm.Controls.Add($btnBP)

    # Run All Button
    $btnRunAll = New-Object System.Windows.Forms.Button
    $btnRunAll.Location = New-Object System.Drawing.Point(355, 285)
    $btnRunAll.Size = New-Object System.Drawing.Size(315, 40)
    $btnRunAll.Text = "Run All Steps (1a + 1b + 1c + 1d)"
    $btnRunAll.BackColor = [System.Drawing.Color]::LightGreen
    $btnRunAll.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnRunAll.Add_Click({
        $btnRunAll.Enabled = $false
        
        # Run each step if available
        if (Get-Command Run-Step1Analysis -ErrorAction SilentlyContinue) {
            Run-Step1Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
        }
        if (Get-Command Run-Step2Analysis -ErrorAction SilentlyContinue) {
            Run-Step2Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
        }
        if (Get-Command Run-Step3Analysis -ErrorAction SilentlyContinue) {
            Run-Step3Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
        }
        if (Get-Command Run-Step4Analysis -ErrorAction SilentlyContinue) {
            Run-Step4Analysis -GovernanceRoot $GovernanceRoot -PbipFolders $pbipFolders
        }
        
        Show-InfoMessage "All available analysis steps complete!`n`nCheck Governance/Analysis_Output/ for CSV files."
        $btnRunAll.Enabled = $true
    })
    $analyzerForm.Controls.Add($btnRunAll)
    
    # Results area
    $resultsLabel = New-Object System.Windows.Forms.Label
    $resultsLabel.Location = New-Object System.Drawing.Point(20, 335)
    $resultsLabel.Size = New-Object System.Drawing.Size(650, 20)
    $resultsLabel.Text = "Status:"
    $resultsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $analyzerForm.Controls.Add($resultsLabel)
    
    $script:analyzerResultsBox = New-Object System.Windows.Forms.TextBox
    $script:analyzerResultsBox.Location = New-Object System.Drawing.Point(20, 360)
    $script:analyzerResultsBox.Size = New-Object System.Drawing.Size(650, 150)
    $script:analyzerResultsBox.Multiline = $true
    $script:analyzerResultsBox.ScrollBars = "Vertical"
    $script:analyzerResultsBox.ReadOnly = $true
    $script:analyzerResultsBox.Font = New-Object System.Drawing.Font("Consolas", 9)
    $script:analyzerResultsBox.Text = "Ready to analyze $($pbipFolders.Count) PBIP folders..."
    $analyzerForm.Controls.Add($script:analyzerResultsBox)
    
    # Show form
    [void]$analyzerForm.ShowDialog()
}

# Functions are automatically available when dot-sourced
