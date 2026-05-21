# Step1-Model.ps1
# Analyze model/model.tmdl files - extract table and role references

function Run-Step1Analysis {
    param(
        [string]$GovernanceRoot,
        [array]$PbipFolders
    )
    
    $timestamp = Get-Timestamp
    $outputFolder = Ensure-OutputDirectory -GovernanceRoot $GovernanceRoot
    
    Write-Host "[Step 1a] Starting model.tmdl analysis..." -ForegroundColor Cyan
    if ($script:analyzerResultsBox) {
        $script:analyzerResultsBox.AppendText("`r`n[Step 1a] Starting model.tmdl analysis...")
        $script:analyzerResultsBox.Refresh()
    }
    
    $results = @()
    
    foreach ($pbipFolder in $PbipFolders) {
        # New structure: pbip_<name> folder
        $pbipFolderName = $pbipFolder.Name
        $semanticModelFolder = $pbipFolder.Parent
        $workspaceFolder = $semanticModelFolder.Parent
        $workspaceName = $workspaceFolder.Name
        $semanticModelName = $semanticModelFolder.Name
        
        # Find model file
        $modelFile = Join-Path $pbipFolder.FullName "model\model.tmdl"
        if (-not (Test-Path $modelFile)) {
            $modelFile = Join-Path $pbipFolder.FullName "model\model"
        }
        
        if (Test-Path $modelFile) {
            $content = Get-Content -Path $modelFile -Raw -Encoding UTF8
            
            # Extract table references using fixed regex
            $tableMatches = [regex]::Matches($content, 'table\s+[\x27"]?(\w+)[\x27"]?')
            foreach ($match in $tableMatches) {
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    ModelName = $semanticModelName
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "TableReference"
                    ObjectName = $match.Groups[1].Value
                    Property1_Name = "Source"
                    Property1_Value = "ModelFile"
                    Property2_Name = ""
                    Property2_Value = ""
                    Property3_Name = ""
                    Property3_Value = ""
                    Property4_Name = ""
                    Property4_Value = ""
                    Property5_Name = ""
                    Property5_Value = ""
                }
            }
            
            # Extract role references
            $roleMatches = [regex]::Matches($content, 'role\s+[\x27"]?(\w+)[\x27"]?')
            foreach ($match in $roleMatches) {
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    ModelName = $semanticModelName
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "RoleReference"
                    ObjectName = $match.Groups[1].Value
                    Property1_Name = "Source"
                    Property1_Value = "ModelFile"
                    Property2_Name = ""
                    Property2_Value = ""
                    Property3_Name = ""
                    Property3_Value = ""
                    Property4_Name = ""
                    Property4_Value = ""
                    Property5_Name = ""
                    Property5_Value = ""
                }
            }
        }
    }
    
    # Export results
    if ($results.Count -gt 0) {
        $csvPath = Join-Path $outputFolder "Step1a_ModelFiles_$timestamp.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        $message = "[Step 1a] OK Complete! $($results.Count) records -> $csvPath"
        Write-Host $message -ForegroundColor Green
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
    else {
        $message = "[Step 1a] No data found"
        Write-Host $message -ForegroundColor Yellow
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
}

# Functions are automatically available when dot-sourced
