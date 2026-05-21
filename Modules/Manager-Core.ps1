# Manager-Core.ps1
# Core PBIP management functions: Scan, Generate, Delete

#region Scan Functions

function Scan-GovernanceStructure {
    param([string]$RootPath)
    
    $results = @()
    Write-Host "Scanning: $RootPath" -ForegroundColor Cyan
    
    # Structure: Governance/WS/WorkspaceName/ModelName/model.pbix
    # Find all .pbix files (excluding reports subfolder)
    $allPbixFiles = Get-ChildItem -Path $RootPath -Filter "*.pbix" -Recurse -File -ErrorAction SilentlyContinue
    Write-Host "Found $($allPbixFiles.Count) total .pbix files" -ForegroundColor Gray
    
    $pbixFiles = $allPbixFiles | Where-Object { $_.DirectoryName -notmatch '\\reports$' }
    Write-Host "After filtering reports folder: $($pbixFiles.Count) semantic model files" -ForegroundColor Gray
    
    foreach ($pbixFile in $pbixFiles) {
        $modelFolder = $pbixFile.Directory
        $workspaceFolder = $modelFolder.Parent
        
        # Check if this is under WS folder
        $wsParent = $workspaceFolder.Parent
        if ($wsParent.Name -ne "WS") {
            Write-Host "  SKIP: $($pbixFile.Name) (not in WS folder structure)" -ForegroundColor Yellow
            continue
        }
        
        # PBIP folder name = pbip_<pbixbasename>
        $pbixBaseName = [System.IO.Path]::GetFileNameWithoutExtension($pbixFile.Name)
        $pbipFolderName = "pbip_$pbixBaseName"
        $pbipFolderPath = Join-Path -Path $modelFolder.FullName -ChildPath $pbipFolderName
        $pbipExists = Test-Path -Path $pbipFolderPath
        
        # Get workspace and dataset IDs from connection.json
        $workspaceId = ""
        $datasetId = ""
        
        # Priority 1: Read from PBIP folder if it exists
        if ($pbipExists) {
            $pbipConnectionJson = Join-Path $pbipFolderPath "connection.json"
            if (Test-Path $pbipConnectionJson) {
                try {
                    $connectionData = Get-Content $pbipConnectionJson -Raw | ConvertFrom-Json
                    $workspaceId = $connectionData.OriginalWorkspaceObjectId
                    if ($connectionData.RemoteArtifacts -and $connectionData.RemoteArtifacts.Count -gt 0) {
                        $datasetId = $connectionData.RemoteArtifacts[0].DatasetId
                    }
                }
                catch {
                    Write-Host "    Warning: Could not parse connection.json in PBIP folder" -ForegroundColor Yellow
                }
            }
        }
        
        # Priority 2: If PBIP doesn't exist, extract from .pbix (it's a ZIP)
        if (-not $pbipExists -or [string]::IsNullOrEmpty($workspaceId)) {
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($pbixFile.FullName)
                $connectionEntry = $zipArchive.Entries | Where-Object { $_.FullName -eq "Connections" }
                
                if ($connectionEntry) {
                    $stream = $connectionEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $connectionsContent = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                    
                    # Parse Connections file (JSON format)
                    $connectionsData = $connectionsContent | ConvertFrom-Json
                    $workspaceId = $connectionsData.OriginalWorkspaceObjectId
                    if ($connectionsData.RemoteArtifacts -and $connectionsData.RemoteArtifacts.Count -gt 0) {
                        $datasetId = $connectionsData.RemoteArtifacts[0].DatasetId
                    }
                }
                
                $zipArchive.Dispose()
            }
            catch {
                # Silent fail - IDs just won't show
            }
        }
        
        # Check for reports folder
        $reportsFolder = Join-Path $modelFolder.FullName "reports"
        $hasReports = Test-Path $reportsFolder
        $reportCount = 0
        if ($hasReports) {
            $reportCount = (Get-ChildItem -Path $reportsFolder -Filter "*.pbix" -ErrorAction SilentlyContinue).Count
        }
        
        $result = [PSCustomObject]@{
            WorkspaceName = $workspaceFolder.Name
            ModelName = $modelFolder.Name
            WorkspaceId = $workspaceId
            DatasetId = $datasetId
            PbixFile = $pbixFile.FullName
            PbixFileName = $pbixFile.Name
            ModelFolderPath = $modelFolder.FullName
            PbipFolderPath = $pbipFolderPath
            PbipFolderName = $pbipFolderName
            PbipExists = $pbipExists
            PbixSizeMB = [math]::Round($pbixFile.Length / 1MB, 2)
            HasReports = $hasReports
            ReportCount = $reportCount
        }
        
        $results += $result
        
        $statusMsg = "PBIP: $pbipExists"
        if ($workspaceId) { 
            $statusMsg += " | WS: $workspaceId | DS: $datasetId" 
        }
        if ($hasReports) { $statusMsg += " | Reports: $reportCount" }
        
        Write-Host "  Found: $($result.WorkspaceName) / $($result.ModelName)" -ForegroundColor $(if($pbipExists){"Green"}else{"Yellow"})
        Write-Host "    $statusMsg" -ForegroundColor Gray
    }
    
    Write-Host "Total semantic models found: $($results.Count)" -ForegroundColor Cyan
    return $results
}

#endregion

#region Generate Functions

function Generate-AllPbip {
    param(
        [array]$ScanResults,
        [string]$PbiToolsPath
    )
    
    if (-not (Show-ConfirmDialog "Generate PBIP folders for ALL $($ScanResults.Count) models (replacing existing)?")) {
        return $false
    }
    
    $progressForm = Create-ProgressWindow -Title "Generating PBIP - All Models"
    $progressForm.Show()
    
    $total = $ScanResults.Count
    $current = 0
    
    foreach ($model in $ScanResults) {
        $current++
        Update-ProgressWindow -Text "Processing $current of $total : $($model.SemanticModelName)" `
                              -Percent ([int](($current / $total) * 100))
        
        # Delete existing PBIP if present
        if ($model.PbipExists) {
            Remove-Item -Path $model.PbipFolderPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Generate PBIP
        try {
            $null = & $PbiToolsPath extract $model.PbixFile -extractFolder $model.PbipFolderPath 2>&1
            
            # Delete Data folder (cache) to save space
            $dataFolder = Join-Path $model.PbipFolderPath "Data"
            if (Test-Path $dataFolder) {
                Write-Host "  Removing Data cache from: $($model.SemanticModelName)" -ForegroundColor Gray
                Remove-Item $dataFolder -Recurse -Force -ErrorAction Stop
            }
            
            $model.PbipExists = $true
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    $progressForm.Close()
    Show-InfoMessage "Generation complete! Processed $total models."
    
    return $true
}

function Generate-MissingPbip {
    param(
        [array]$ScanResults,
        [string]$PbiToolsPath
    )
    
    $missingModels = $ScanResults | Where-Object { -not $_.PbipExists }
    
    if ($missingModels.Count -eq 0) {
        Show-InfoMessage "All models already have PBIP folders."
        return $false
    }
    
    if (-not (Show-ConfirmDialog "Generate PBIP folders for $($missingModels.Count) missing models?")) {
        return $false
    }
    
    $progressForm = Create-ProgressWindow -Title "Generating PBIP - Missing Only"
    $progressForm.Show()
    
    $total = $missingModels.Count
    $current = 0
    
    foreach ($model in $missingModels) {
        $current++
        Update-ProgressWindow -Text "Processing $current of $total : $($model.SemanticModelName)" `
                              -Percent ([int](($current / $total) * 100))
        
        try {
            $null = & $PbiToolsPath extract $model.PbixFile -extractFolder $model.PbipFolderPath 2>&1
            
            # Delete Data folder (cache) to save space
            $dataFolder = Join-Path $model.PbipFolderPath "Data"
            if (Test-Path $dataFolder) {
                Write-Host "  Removing Data cache from: $($model.SemanticModelName)" -ForegroundColor Gray
                Remove-Item $dataFolder -Recurse -Force -ErrorAction Stop
            }
            
            $model.PbipExists = $true
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    $progressForm.Close()
    Show-InfoMessage "Generation complete! Processed $total models."
    
    return $true
}

#endregion

#region Delete Functions

function Delete-AllPbip {
    param([array]$ScanResults)
    
    $existingModels = $ScanResults | Where-Object { $_.PbipExists }
    
    if ($existingModels.Count -eq 0) {
        Show-InfoMessage "No PBIP folders to delete."
        return $false
    }
    
    if (-not (Show-ConfirmDialog "DELETE all $($existingModels.Count) PBIP folders? This cannot be undone!")) {
        return $false
    }
    
    $progressForm = Create-ProgressWindow -Title "Deleting PBIP Folders"
    $progressForm.Show()
    
    $total = $existingModels.Count
    $current = 0
    
    foreach ($model in $existingModels) {
        $current++
        Update-ProgressWindow -Text "Deleting $current of $total : $($model.SemanticModelName)" `
                              -Percent ([int](($current / $total) * 100))
        
        try {
            Remove-Item -Path $model.PbipFolderPath -Recurse -Force -ErrorAction Stop
            $model.PbipExists = $false
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    $progressForm.Close()
    Show-InfoMessage "Deletion complete! Removed $total PBIP folders."
    
    return $true
}

#endregion

# Functions are automatically available when dot-sourced
