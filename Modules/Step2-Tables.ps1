# Step2-Tables.ps1
# Analyze model/tables/*.tmdl files - extract source types and M queries

function Run-Step2Analysis {
    param(
        [string]$GovernanceRoot,
        [array]$PbipFolders
    )
    
    $timestamp = Get-Timestamp
    $outputFolder = Ensure-OutputDirectory -GovernanceRoot $GovernanceRoot
    
    Write-Host "[Step 1b] Starting tables folder analysis..." -ForegroundColor Cyan
    if ($script:analyzerResultsBox) {
        $script:analyzerResultsBox.AppendText("`r`n[Step 1b] Starting tables folder analysis...")
        $script:analyzerResultsBox.Refresh()
    }
    
    $results = @()
    
    foreach ($pbipFolder in $PbipFolders) {
        $semanticModelFolder = $pbipFolder.Parent
        $workspaceFolder = $semanticModelFolder.Parent
        $workspaceName = $workspaceFolder.Name
        $semanticModelName = $semanticModelFolder.Name
        
        
        $tablesFolder = Join-Path $pbipFolder.FullName "model\tables"
        
        if (Test-Path $tablesFolder) {
            $tableFiles = Get-ChildItem -Path $tablesFolder -File -ErrorAction SilentlyContinue
            
            foreach ($tableFile in $tableFiles) {
                $content = Get-Content -Path $tableFile.FullName -Raw -Encoding UTF8
                
                # Detect source type
                $detectedSource = "Unknown"
                if ($content -match "Excel\.Workbook") { $detectedSource = "Excel" }
                elseif ($content -match "SharePoint|Sharepoint") { $detectedSource = "SharePoint" }
                elseif ($content -match "Web\.Contents|Web\.Page") { $detectedSource = "Web" }
                elseif ($content -match "Sql\.Database|AzureSql") { $detectedSource = "Azure SQL" }
                elseif ($content -match "Sql\.Databases") { $detectedSource = "SQL Server" }
                elseif ($content -match "Oracle|Odbc\.DataSource.*Oracle") { $detectedSource = "Oracle" }
                elseif ($content -match "Databricks|AzureDatabricks") { $detectedSource = "Databricks" }
                elseif ($content -match "PostgreSql|Npgsql") { $detectedSource = "PostgreSQL" }
                elseif ($content -match "MySQL") { $detectedSource = "MySQL" }
                elseif ($content -match "Table\.FromRows") { $detectedSource = "Manual Input" }
                elseif ($content -match "Folder\.Files|File\.Contents") { $detectedSource = "Local File" }
                elseif ($content -match "expression\s*=") { $detectedSource = "M Query" }
                
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    
                    ModelName = $semanticModelName
                    
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "TableDetail"
                    ObjectName = $tableFile.BaseName
                    Property1_Name = "SourceType"
                    Property1_Value = $detectedSource
                    Property2_Name = "FileName"
                    Property2_Value = $tableFile.Name
                    Property3_Name = "FileSize"
                    Property3_Value = [math]::Round($tableFile.Length / 1KB, 2).ToString() + " KB"
                    Property4_Name = ""
                    Property4_Value = ""
                    Property5_Name = "FullContent"
                    Property5_Value = $content
                }
            }
        }
    }
    
    # Export results
    if ($results.Count -gt 0) {
        $csvPath = Join-Path $outputFolder "Step1b_Tables_$timestamp.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        # Count source types
        $sourceTypes = $results | Group-Object -Property Property1_Value | 
            Select-Object Name, Count | 
            Sort-Object -Property Count -Descending
        
        $message = "[Step 1b] OK Complete! $($results.Count) tables -> $csvPath"
        Write-Host $message -ForegroundColor Green
        Write-Host "  Source breakdown:" -ForegroundColor Gray
        foreach ($src in $sourceTypes) {
            Write-Host "    $($src.Name): $($src.Count)" -ForegroundColor Gray
        }
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
    else {
        $message = "[Step 1b] No data found"
        Write-Host $message -ForegroundColor Yellow
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
}

# Functions are automatically available when dot-sourced
