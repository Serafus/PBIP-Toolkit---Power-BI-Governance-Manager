# BestPractice-Analyzer.ps1
# A lightweight best-practice analyzer for extracted PBIP models. It parses the
# TMDL under each pbip_<model>\model\ folder and runs a customizable rule set
# over tables, columns, measures and roles - a free, offline echo of the
# governance / CI checks that platforms like Dawiso charge for.
#
# The rule set is data-driven (Get-BestPracticeRules): each rule carries its own
# Test scriptblock, so rules can be disabled, re-prioritised or added without
# touching the engine.

#region TMDL parsing

function Get-TmdlObjectName {
    # Extracts the (possibly quoted) name from a TMDL header line such as
    #   table 'Sales'    |    measure "Total" = ...    |    column Amount
    param([string]$Line, [string]$Keyword)
    $m = [regex]::Match($Line, "^\s*$Keyword\s+(?:'([^']*)'|""([^""]*)""|([^\s=]+))")
    if (-not $m.Success) { return $null }
    foreach ($g in 1..3) { if ($m.Groups[$g].Success) { return $m.Groups[$g].Value } }
    return $null
}

function ConvertFrom-ModelTmdl {
    <#
    .SYNOPSIS
        Parses one extracted model (a pbip_<name> folder) into a structured
        object: Tables (with Columns and Measures) and Roles.
    #>
    param([Parameter(Mandatory)][string]$PbipFolder)

    $modelDir = Join-Path $PbipFolder "model"
    $tablesDir = Join-Path $modelDir "tables"
    $rolesDir  = Join-Path $modelDir "roles"

    $tables = @()
    if (Test-Path $tablesDir) {
        foreach ($file in (Get-ChildItem -Path $tablesDir -File -ErrorAction SilentlyContinue)) {
            $tables += ConvertFrom-TableTmdl -Content (Get-Content $file.FullName -Raw -Encoding UTF8)
        }
    }

    # Roles - one tablePermission line per protected table.
    $roles = @()
    if (Test-Path $rolesDir) {
        foreach ($file in (Get-ChildItem -Path $rolesDir -File -ErrorAction SilentlyContinue)) {
            $content = Get-Content $file.FullName -Raw -Encoding UTF8
            $name = Get-TmdlObjectName -Line (($content -split "`r?`n") | Where-Object { $_ -match '^\s*role\s' } | Select-Object -First 1) -Keyword 'role'
            $perms = ([regex]::Matches($content, '(?m)^\s*tablePermission\b')).Count
            $roles += [PSCustomObject]@{ Name = $name; TablePermissionCount = $perms }
        }
    }

    $measureCount = (@($tables | ForEach-Object { $_.Measures }) | Measure-Object).Count

    return [PSCustomObject]@{
        Tables       = @($tables)
        Roles        = @($roles)
        MeasureCount = $measureCount
    }
}

function ConvertFrom-TableTmdl {
    # Parses a single table .tmdl file into a table object.
    param([string]$Content)

    $lines = $Content -split "`r?`n"
    $table = [PSCustomObject]@{
        Name = $null; IsHidden = $false; Description = ""
        DataCategory = ""; IsAuto = $false
        Columns = @(); Measures = @()
    }
    $pendingDesc = @()
    $cur = $null          # current indent-1 object (column/measure) being filled
    $curKind = $null      # 'column' | 'measure' | 'other'

    foreach ($raw in $lines) {
        if ($raw -match '^\s*$') { continue }
        $trimmed = $raw -replace '^[\t ]+', ''
        $indent  = ($raw.Length - $trimmed.Length)

        # Description lines (/// ...) belong to the NEXT object header.
        if ($trimmed -match '^///\s?(.*)$') { $pendingDesc += $Matches[1]; continue }

        if ($indent -eq 0 -and $trimmed -match '^table\b') {
            $table.Name = Get-TmdlObjectName -Line $trimmed -Keyword 'table'
            $table.Description = ($pendingDesc -join ' ').Trim()
            $pendingDesc = @()
            if ($table.Name -match '^(LocalDateTable_|DateTableTemplate_)') { $table.IsAuto = $true }
            continue
        }

        # Indent-1: either an object header or a table-level property.
        if ($indent -eq 1) {
            if ($trimmed -match '^(column|measure|partition|hierarchy|calculationGroup)\b') {
                $kw = $Matches[1]
                if ($kw -eq 'column') {
                    $cur = [PSCustomObject]@{
                        Name = (Get-TmdlObjectName -Line $trimmed -Keyword 'column')
                        DataType = ""; IsHidden = $false; Description = ($pendingDesc -join ' ').Trim()
                        SummarizeBy = ""; DisplayFolder = ""
                        IsCalculated = ($trimmed -match '=\s*\S')
                    }
                    $table.Columns += $cur; $curKind = 'column'
                }
                elseif ($kw -eq 'measure') {
                    $cur = [PSCustomObject]@{
                        Name = (Get-TmdlObjectName -Line $trimmed -Keyword 'measure')
                        Description = ($pendingDesc -join ' ').Trim()
                        DisplayFolder = ""; FormatString = ""
                    }
                    $table.Measures += $cur; $curKind = 'measure'
                }
                else { $cur = $null; $curKind = 'other' }
                $pendingDesc = @()
            }
            else {
                # table-level property
                if ($trimmed -match '^isHidden\b')        { $table.IsHidden = $true }
                if ($trimmed -match '^dataCategory:\s*(.+)$') { $table.DataCategory = $Matches[1].Trim() }
                $pendingDesc = @()
            }
            continue
        }

        # Indent >= 2: property of the current column/measure.
        if ($indent -ge 2 -and $cur) {
            if ($curKind -eq 'column') {
                if ($trimmed -match '^dataType:\s*(.+)$')     { $cur.DataType     = $Matches[1].Trim() }
                if ($trimmed -match '^summarizeBy:\s*(.+)$')  { $cur.SummarizeBy  = $Matches[1].Trim() }
                if ($trimmed -match '^displayFolder:\s*(.+)$'){ $cur.DisplayFolder= $Matches[1].Trim() }
                if ($trimmed -match '^isHidden\b')            { $cur.IsHidden     = $true }
            }
            elseif ($curKind -eq 'measure') {
                if ($trimmed -match '^formatString:\s*(.+)$')  { $cur.FormatString  = $Matches[1].Trim() }
                if ($trimmed -match '^displayFolder:\s*(.+)$') { $cur.DisplayFolder = $Matches[1].Trim() }
            }
        }
    }
    return $table
}

#endregion

#region Rule set (data-driven, customizable)

function Get-BestPracticeRules {
    <#
    .SYNOPSIS
        Returns the built-in best-practice rules. Each rule has a Scope
        (Model/Table/Column/Measure/Role) and a Test scriptblock returning
        $true when the item VIOLATES the rule. Callers may filter, re-prioritise
        or append rules before passing them to Invoke-BestPracticeAnalysis.
    #>
    @(
        [PSCustomObject]@{ Id="BP01"; Scope="Measure"; Severity="Medium"; Category="Documentation"
            Title="Measure has no description"
            Test={ param($o) [string]::IsNullOrWhiteSpace($o.Description) } }

        [PSCustomObject]@{ Id="BP02"; Scope="Measure"; Severity="Low"; Category="Organization"
            Title="Measure is not in a display folder"
            Test={ param($o) [string]::IsNullOrWhiteSpace($o.DisplayFolder) } }

        [PSCustomObject]@{ Id="BP03"; Scope="Measure"; Severity="Medium"; Category="Formatting"
            Title="Measure has no format string"
            Test={ param($o) [string]::IsNullOrWhiteSpace($o.FormatString) } }

        [PSCustomObject]@{ Id="BP04"; Scope="Table"; Severity="Low"; Category="Documentation"
            Title="Table has no description"
            Test={ param($o) (-not $o.IsAuto) -and [string]::IsNullOrWhiteSpace($o.Description) } }

        [PSCustomObject]@{ Id="BP05"; Scope="Column"; Severity="Info"; Category="Documentation"
            Title="Visible column has no description"
            Test={ param($o) (-not $o.IsHidden) -and [string]::IsNullOrWhiteSpace($o.Description) } }

        [PSCustomObject]@{ Id="BP06"; Scope="Role"; Severity="High"; Category="Security"
            Title="RLS role has no table permissions (empty role)"
            Test={ param($o) [int]$o.TablePermissionCount -eq 0 } }

        [PSCustomObject]@{ Id="BP07"; Scope="Column"; Severity="Medium"; Category="Modeling"
            Title="Key/ID column is summarized by default (set summarizeBy: none)"
            Test={ param($o)
                ($o.Name -match '(?i)(id|key|code|number|guid)$') -and
                ($o.DataType -match '(?i)int|double|decimal|number') -and
                ($o.SummarizeBy -eq '' -or $o.SummarizeBy -match '(?i)sum|count|average|min|max') } }

        [PSCustomObject]@{ Id="BP08"; Scope="Column"; Severity="Low"; Category="Naming"
            Title="Object has a default/generic name"
            Test={ param($o) $o.Name -match '(?i)^(column|measure|query|table)\s?\d+$' } }

        [PSCustomObject]@{ Id="BP09"; Scope="Table"; Severity="Info"; Category="Performance"
            Title="Auto date/time table present (consider disabling auto date/time)"
            Test={ param($o) [bool]$o.IsAuto } }

        [PSCustomObject]@{ Id="BP10"; Scope="Column"; Severity="Info"; Category="Modeling"
            Title="Calculated column (consider a measure where possible)"
            Test={ param($o) [bool]$o.IsCalculated } }

        [PSCustomObject]@{ Id="BP11"; Scope="Model"; Severity="Medium"; Category="Modeling"
            Title="Model defines no measures"
            Test={ param($o) [int]$o.MeasureCount -eq 0 } }
    )
}

#endregion

#region Analysis engine

function Invoke-BestPracticeAnalysis {
    <#
    .SYNOPSIS
        Runs the rule set over every extracted model under a Governance root.
    .PARAMETER GovernanceRoot
        Governance root - pbip_<name> folders are discovered recursively.
    .PARAMETER Rules
        Rule set to apply. Defaults to Get-BestPracticeRules.
    .OUTPUTS
        PSCustomObject with .Violations (flat list) and .Summary.
    #>
    param(
        [Parameter(Mandatory)][string]$GovernanceRoot,
        $Rules = $null,
        [scriptblock]$ProgressCallback
    )
    if (-not $Rules) { $Rules = Get-BestPracticeRules }
    $rulesByScope = @{}
    foreach ($r in $Rules) {
        if (-not $rulesByScope.ContainsKey($r.Scope)) { $rulesByScope[$r.Scope] = @() }
        $rulesByScope[$r.Scope] += $r
    }

    $pbipFolders = @(Get-ChildItem -Path $GovernanceRoot -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^pbip_' })

    # ArrayList (reference type) so the $emit scriptblock can append across scopes.
    $violations = New-Object System.Collections.ArrayList
    $modelCount = 0
    $i = 0
    foreach ($pf in $pbipFolders) {
        $i++
        $modelName = $pf.Parent.Name
        $workspace = $pf.Parent.Parent.Name
        if ($ProgressCallback) {
            & $ProgressCallback "Analyzing $modelName" ([int](($i / [Math]::Max(1,$pbipFolders.Count)) * 100))
        }
        $model = ConvertFrom-ModelTmdl -PbipFolder $pf.FullName
        if (-not $model.Tables -and -not $model.Roles) { continue }
        $modelCount++

        $emit = {
            param($rule, $objType, $objName, $tableName)
            [void]$violations.Add([PSCustomObject]@{
                Workspace = $workspace; Model = $modelName
                Severity  = $rule.Severity; Category = $rule.Category
                RuleId    = $rule.Id; Rule = $rule.Title
                ObjectType= $objType; Table = $tableName; Object = $objName
            })
        }

        foreach ($rule in @($rulesByScope['Model'])) {
            if (& $rule.Test $model) { & $emit $rule "Model" $modelName "" }
        }
        foreach ($t in @($model.Tables)) {
            foreach ($rule in @($rulesByScope['Table'])) {
                if (& $rule.Test $t) { & $emit $rule "Table" $t.Name $t.Name }
            }
            foreach ($c in @($t.Columns)) {
                foreach ($rule in @($rulesByScope['Column'])) {
                    if (& $rule.Test $c) { & $emit $rule "Column" $c.Name $t.Name }
                }
            }
            foreach ($mz in @($t.Measures)) {
                foreach ($rule in @($rulesByScope['Measure'])) {
                    if (& $rule.Test $mz) { & $emit $rule "Measure" $mz.Name $t.Name }
                }
            }
        }
        foreach ($role in @($model.Roles)) {
            foreach ($rule in @($rulesByScope['Role'])) {
                if (& $rule.Test $role) { & $emit $rule "Role" $role.Name "" }
            }
        }
    }

    $order = @{ High=0; Medium=1; Low=2; Info=3 }
    $sevCounts = $violations | Group-Object Severity |
        ForEach-Object { [PSCustomObject]@{ Severity = $_.Name; Count = $_.Count } } |
        Sort-Object { $order[$_.Severity] }

    return [PSCustomObject]@{
        ModelsAnalyzed = $modelCount
        RuleCount      = @($Rules).Count
        Violations     = @($violations | Sort-Object { $order[$_.Severity] }, Workspace, Model)
        SeverityCounts = @($sevCounts)
    }
}

#endregion

#region Export

function Export-BestPracticeReport {
    <#
    .SYNOPSIS
        Writes the analysis to CSV and a markdown report under
        <GovernanceRoot>\Analysis_Output.
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $out = Join-Path $GovernanceRoot "Analysis_Output"
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    $csv = Join-Path $out "BestPractice_$ts.csv"
    if (@($Result.Violations).Count -gt 0) {
        $Result.Violations | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    }

    $md = Join-Path $out "BestPractice_$ts.md"
    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"
    [void]$sb.Append("# Power BI Best-Practice Analysis$nl$nl")
    [void]$sb.Append("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')$nl")
    [void]$sb.Append("Models analyzed: $($Result.ModelsAnalyzed)  |  Rules: $($Result.RuleCount)  |  Findings: $(@($Result.Violations).Count)$nl$nl")
    [void]$sb.Append("## By severity$nl$nl")
    foreach ($s in $Result.SeverityCounts) { [void]$sb.Append("- $($s.Severity): $($s.Count)$nl") }
    [void]$sb.Append($nl + "## Findings$nl$nl")
    foreach ($g in (@($Result.Violations) | Group-Object Workspace, Model)) {
        [void]$sb.Append("### $($g.Name)$nl$nl")
        foreach ($v in $g.Group) {
            $where = if ($v.Table) { " ($($v.Table))" } else { "" }
            [void]$sb.Append("- **[$($v.Severity)]** $($v.Rule) - $($v.ObjectType): $($v.Object)$where$nl")
        }
        [void]$sb.Append($nl)
    }
    $sb.ToString() | Set-Content -Path $md -Encoding UTF8

    Write-Host "Best-practice report written to: $out" -ForegroundColor Green
    return $md
}

#endregion

#region GUI

function Show-BestPracticeWindow {
    <#
    .SYNOPSIS
        Window that runs the best-practice analyzer over the extracted models
        and shows the findings grouped by severity.
    #>
    param([Parameter(Mandatory)][string]$GovernanceRoot)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Best-Practice Analyzer"
    $form.Size = New-Object System.Drawing.Size(840, 620)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(800, 20)
    $lbl.Text = "Parses extracted TMDL and flags best-practice issues across all models."
    $form.Controls.Add($lbl)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Location = New-Object System.Drawing.Point(12, 38)
    $btnRun.Size = New-Object System.Drawing.Size(160, 32)
    $btnRun.Text = "Run Analysis"
    $btnRun.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnRun)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Location = New-Object System.Drawing.Point(182, 38)
    $btnExport.Size = New-Object System.Drawing.Size(160, 32)
    $btnExport.Text = "Export Report"
    $btnExport.Enabled = $false
    $form.Controls.Add($btnExport)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(352, 42)
    $progress.Size = New-Object System.Drawing.Size(460, 24)
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 80)
    $output.Size = New-Object System.Drawing.Size(800, 460)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 548)
    $status.Size = New-Object System.Drawing.Size(800, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "Ready."
    $form.Controls.Add($status)

    $script:BpResult = $null

    $btnRun.Add_Click({
        $output.Clear()
        $btnRun.Enabled = $false
        $status.Text = "Analyzing..."
        try {
            $cb = {
                param($msg,$pct)
                $progress.Value = [Math]::Min(100,[Math]::Max(0,$pct))
                $status.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $res = Invoke-BestPracticeAnalysis -GovernanceRoot $GovernanceRoot -ProgressCallback $cb
            $script:BpResult = $res

            $output.AppendText("BEST-PRACTICE ANALYSIS`r`n")
            $output.AppendText(("=" * 76) + "`r`n")
            $output.AppendText(("Models analyzed : {0}`r`n" -f $res.ModelsAnalyzed))
            $output.AppendText(("Rules applied   : {0}`r`n" -f $res.RuleCount))
            $output.AppendText(("Findings        : {0}`r`n`r`n" -f @($res.Violations).Count))
            foreach ($s in $res.SeverityCounts) {
                $output.AppendText(("   {0,-7} {1}`r`n" -f $s.Severity, $s.Count))
            }
            $output.AppendText("`r`n")

            if (@($res.Violations).Count -eq 0) {
                $output.AppendText("No findings - or no extracted models were found. Generate PBIP first.`r`n")
            }
            foreach ($g in (@($res.Violations) | Group-Object Workspace, Model)) {
                $output.AppendText(("-- {0} " -f $g.Name) + ("-" * [Math]::Max(1, 70 - $g.Name.Length)) + "`r`n")
                foreach ($v in $g.Group) {
                    $where = if ($v.Table) { " ($($v.Table))" } else { "" }
                    $output.AppendText(("  [{0,-6}] {1}`r`n" -f $v.Severity, $v.Rule))
                    $output.AppendText(("            {0}: {1}{2}`r`n" -f $v.ObjectType, $v.Object, $where))
                }
                $output.AppendText("`r`n")
            }
            $btnExport.Enabled = (@($res.Violations).Count -gt 0)
            $status.Text = "Analysis complete - $(@($res.Violations).Count) finding(s)."
        }
        catch {
            $output.AppendText("`r`nERROR: $($_.Exception.Message)`r`n")
            $status.Text = "Failed."
        }
        finally {
            $btnRun.Enabled = $true
            $progress.Value = 0
        }
    })

    $btnExport.Add_Click({
        if (-not $script:BpResult) { return }
        $path = Export-BestPracticeReport -Result $script:BpResult -GovernanceRoot $GovernanceRoot
        $status.Text = "Exported: $path"
        [System.Windows.Forms.MessageBox]::Show("Report written:`n$path","Export complete") | Out-Null
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
