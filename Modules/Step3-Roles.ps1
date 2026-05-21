# Step3-Roles.ps1
# Analyze model/roles/*.tmdl files - extract RLS definitions

function Run-Step3Analysis {
    param(
        [string]$GovernanceRoot,
        [array]$PbipFolders
    )
    
    $timestamp = Get-Timestamp
    $outputFolder = Ensure-OutputDirectory -GovernanceRoot $GovernanceRoot
    
    Write-Host "[Step 1c] Starting roles folder analysis..." -ForegroundColor Cyan
    if ($script:analyzerResultsBox) {
        $script:analyzerResultsBox.AppendText("`r`n[Step 1c] Starting roles folder analysis...")
        $script:analyzerResultsBox.Refresh()
    }
    
    $results = @()
    
    foreach ($pbipFolder in $PbipFolders) {
        $semanticModelFolder = $pbipFolder.Parent
        $workspaceFolder = $semanticModelFolder.Parent
        $workspaceName = $workspaceFolder.Name
        $semanticModelName = $semanticModelFolder.Name
        
        
        $rolesFolder = Join-Path $pbipFolder.FullName "model\roles"
        
        if (Test-Path $rolesFolder) {
            $roleFiles = Get-ChildItem -Path $rolesFolder -File -ErrorAction SilentlyContinue
            
            foreach ($roleFile in $roleFiles) {
                $content = Get-Content -Path $roleFile.FullName -Raw -Encoding UTF8
                
                # Extract table permissions
                $tablePermissions = [regex]::Matches($content, 'tablePermission\s+(\w+)\s*=')
                $affectedTables = $tablePermissions | ForEach-Object { $_.Groups[1].Value }
                $tableCount = $affectedTables.Count
                
                # Check for model permission
                $hasModelPermission = $content -match 'modelPermission\s*='
                
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    
                    ModelName = $semanticModelName
                    
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "RoleDetail"
                    ObjectName = $roleFile.BaseName
                    Property1_Name = "FileName"
                    Property1_Value = $roleFile.Name
                    Property2_Name = "TablePermissions"
                    Property2_Value = $tableCount.ToString()
                    Property3_Name = "AffectedTables"
                    Property3_Value = ($affectedTables -join ", ")
                    Property4_Name = "HasModelPermission"
                    Property4_Value = $hasModelPermission.ToString()
                    Property5_Name = "FullContent"
                    Property5_Value = $content
                }
                
                # Create individual records for each table permission
                foreach ($table in $affectedTables) {
                    $results += [PSCustomObject]@{
                        Timestamp = $timestamp
                        WorkspaceName = $workspaceName
                        
                        ModelName = $semanticModelName
                        
                        PbipFolderPath = $pbipFolder.FullName
                        ObjectType = "TablePermission"
                        ObjectName = "$($roleFile.BaseName).$table"
                        Property1_Name = "RoleName"
                        Property1_Value = $roleFile.BaseName
                        Property2_Name = "TableName"
                        Property2_Value = $table
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
    }
    
    # Export results
    if ($results.Count -gt 0) {
        $csvPath = Join-Path $outputFolder "Step1c_Roles_$timestamp.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        $roleDetails = $results | Where-Object { $_.ObjectType -eq "RoleDetail" }
        $tablePerms = $results | Where-Object { $_.ObjectType -eq "TablePermission" }
        
        $message = "[Step 1c] OK Complete! $($roleDetails.Count) roles, $($tablePerms.Count) permissions -> $csvPath"
        Write-Host $message -ForegroundColor Green
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
    else {
        $message = "[Step 1c] No data found"
        Write-Host $message -ForegroundColor Yellow
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
}

# Functions are automatically available when dot-sourced
