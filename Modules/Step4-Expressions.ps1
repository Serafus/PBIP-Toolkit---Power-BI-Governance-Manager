# Step4-Expressions.ps1
# Analyze model/expressions.tmdl - extract shared M expressions / parameters

function Run-Step4Analysis {
    param(
        [string]$GovernanceRoot,
        [array]$PbipFolders
    )
    
    $timestamp = Get-Timestamp
    $outputFolder = Ensure-OutputDirectory -GovernanceRoot $GovernanceRoot
    
    Write-Host "[Step 1d] Starting expressions folder analysis..." -ForegroundColor Cyan
    if ($script:analyzerResultsBox) {
        $script:analyzerResultsBox.AppendText("`r`n[Step 1d] Starting expressions folder analysis...")
        $script:analyzerResultsBox.Refresh()
    }
    
    $results = @()
    
    foreach ($pbipFolder in $PbipFolders) {
        $semanticModelFolder = $pbipFolder.Parent
        $workspaceFolder = $semanticModelFolder.Parent
        $workspaceName = $workspaceFolder.Name
        $semanticModelName = $semanticModelFolder.Name
        
        
        # expressions.tmdl is a SINGLE FILE in the model folder
        $expressionsFile = Join-Path $pbipFolder.FullName "model\expressions.tmdl"
        
        if (Test-Path $expressionsFile) {
            $content = Get-Content -Path $expressionsFile -Raw -Encoding UTF8
            
            # Parse expressions - typically contains multiple expression definitions
            # Example: expression <name> = <dax code>
            $expressionMatches = [regex]::Matches($content, 'expression\s+[\x27"]?([^\x27"\s=]+)[\x27"]?\s*=')
            
            foreach ($match in $expressionMatches) {
                $exprName = $match.Groups[1].Value
                
                # Try to extract the expression content (get text after the = sign)
                $exprPattern = "expression\s+[\x27""]?$exprName[\x27""]?\s*=\s*([^`r`n]+)"
                $exprContentMatch = [regex]::Match($content, $exprPattern)
                $exprContent = if ($exprContentMatch.Success) { 
                    $exprContentMatch.Groups[1].Value.Trim() 
                } else { 
                    "" 
                }
                
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    
                    ModelName = $semanticModelName
                    
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "Expression"
                    ObjectName = $exprName
                    Property1_Name = "SourceFile"
                    Property1_Value = "expressions.tmdl"
                    Property2_Name = "ExpressionContent"
                    Property2_Value = $exprContent
                    Property3_Name = ""
                    Property3_Value = ""
                    Property4_Name = ""
                    Property4_Value = ""
                    Property5_Name = "FullFileContent"
                    Property5_Value = $content
                }
            }
            
            # If no expressions found by regex, create a single record with full file
            if ($expressionMatches.Count -eq 0) {
                $results += [PSCustomObject]@{
                    Timestamp = $timestamp
                    WorkspaceName = $workspaceName
                    
                    ModelName = $semanticModelName
                    
                    PbipFolderPath = $pbipFolder.FullName
                    ObjectType = "ExpressionsFile"
                    ObjectName = "expressions.tmdl"
                    Property1_Name = "SourceFile"
                    Property1_Value = "expressions.tmdl"
                    Property2_Name = "FileSize"
                    Property2_Value = [math]::Round((Get-Item $expressionsFile).Length / 1KB, 2).ToString() + " KB"
                    Property3_Name = ""
                    Property3_Value = ""
                    Property4_Name = ""
                    Property4_Value = ""
                    Property5_Name = "FullFileContent"
                    Property5_Value = $content
                }
            }
        }
    }
    
    # Export results
    if ($results.Count -gt 0) {
        $csvPath = Join-Path $outputFolder "Step1d_Expressions_$timestamp.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        
        # Count expression types
        $exprTypes = $results | Group-Object -Property Property1_Value | 
            Select-Object Name, Count | 
            Sort-Object -Property Count -Descending
        
        $message = "[Step 1d] OK Complete! $($results.Count) expressions -> $csvPath"
        Write-Host $message -ForegroundColor Green
        Write-Host "  Expression breakdown:" -ForegroundColor Gray
        foreach ($type in $exprTypes) {
            Write-Host "    $($type.Name): $($type.Count)" -ForegroundColor Gray
        }
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
    else {
        $examplePath = if ($PbipFolders.Count -gt 0) { 
            $firstPbip = $PbipFolders[0].FullName
            "Expected: $firstPbip\model\expressions.tmdl"
        } else {
            "Expected: <GovernanceRoot>\WS\<Workspace>\<Model>\pbip_<Model>\model\expressions.tmdl"
        }
        
        $message = "[Step 1d] No expressions.tmdl file found (normal - most models don't have expressions)`n$examplePath"
        Write-Host $message -ForegroundColor Yellow
        
        if ($script:analyzerResultsBox) {
            $script:analyzerResultsBox.AppendText("`r`n$message")
            $script:analyzerResultsBox.Refresh()
        }
    }
}

# Functions are automatically available when dot-sourced
