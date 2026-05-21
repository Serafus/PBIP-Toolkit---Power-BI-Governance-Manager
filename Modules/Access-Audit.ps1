# Access-Audit.ps1
# Audits workspace-level access across the tenant using the Power BI Admin API.
# The toolkit already checks row-level security inside models (TMDL roles); this
# module covers the other half - who can reach each workspace and at what level.
#
# It pulls every workspace with its role assignments in one paged call
# (admin/groups with $expand=users) and flags the governance risks: workspaces
# with no admin, a single admin (bus factor), external/guest users, very wide
# sharing, and access granted indirectly through security groups.
#
# Depends on Connect-PbiApi / Invoke-PbiRestApi / Test-PbiApiConnection from
# API-Scanner.ps1, so this module must load after it. Needs Tenant.Read.All.

#region Retrieval

function Get-WorkspaceAccess {
    <#
    .SYNOPSIS
        Returns every (non-personal) workspace with its role assignments.
    .DESCRIPTION
        Calls GET admin/groups with $expand=users, paged by $top/$skip
        (max 5000 per page).
    #>
    param([scriptblock]$ProgressCallback)

    if (-not (Test-PbiApiConnection)) {
        throw "Not connected to the Power BI API. Run Connect-PbiApi first."
    }

    $result = @()
    $top = 5000
    $skip = 0
    while ($true) {
        $path = 'admin/groups?$top=' + $top + '&$skip=' + $skip + '&$expand=users'
        $resp = Invoke-PbiRestApi -Path $path
        $batch = @($resp.value)
        foreach ($ws in $batch) {
            if ($ws.type -eq 'PersonalGroup') { continue }
            $users = foreach ($u in @($ws.users)) {
                $id = [string]$u.identifier
                $isExternal = ($u.principalType -eq 'User') -and
                    (($id -match '#EXT#') -or ([string]$u.emailAddress -match '#ext#') -or
                     ($u.userType -eq 'Guest'))
                [PSCustomObject]@{
                    Name          = $u.displayName
                    Email         = $u.emailAddress
                    AccessRight   = $u.groupUserAccessRight
                    PrincipalType = $u.principalType
                    IsExternal    = [bool]$isExternal
                }
            }
            $result += [PSCustomObject]@{
                WorkspaceId   = $ws.id
                WorkspaceName = $ws.name
                Type          = $ws.type
                State         = $ws.state
                IsOnDedicated = [bool]$ws.isOnDedicatedCapacity
                CapacityId    = $ws.capacityId
                Users         = @($users)
            }
        }
        if ($ProgressCallback) { & $ProgressCallback "Workspaces read: $($result.Count)" 60 }
        if ($batch.Count -lt $top) { break }
        $skip += $top
    }
    return @($result)
}

#endregion

#region Audit

function Get-AccessAudit {
    <#
    .SYNOPSIS
        Aggregates workspace access into per-workspace counts and a findings
        list (governance risks).
    .PARAMETER WidelySharedThreshold
        Total principals at/above which a workspace is flagged as widely shared.
    #>
    param(
        [Parameter(Mandatory)]$WorkspaceAccess,
        [int]$WidelySharedThreshold = 25
    )

    $rows = @()
    # ArrayList (reference type) so the $add scriptblock can append across scopes.
    $findings = New-Object System.Collections.ArrayList
    foreach ($ws in @($WorkspaceAccess)) {
        $u = @($ws.Users)
        $admins  = @($u | Where-Object { $_.AccessRight -eq 'Admin' })
        $members = @($u | Where-Object { $_.AccessRight -eq 'Member' })
        $contrib = @($u | Where-Object { $_.AccessRight -eq 'Contributor' })
        $viewers = @($u | Where-Object { $_.AccessRight -eq 'Viewer' })
        $groups  = @($u | Where-Object { $_.PrincipalType -eq 'Group' })
        $apps    = @($u | Where-Object { $_.PrincipalType -eq 'App' })
        $ext     = @($u | Where-Object { $_.IsExternal })

        $rows += [PSCustomObject]@{
            WorkspaceName = $ws.WorkspaceName
            WorkspaceId   = $ws.WorkspaceId
            State         = $ws.State
            OnDedicated   = $ws.IsOnDedicated
            Admins        = $admins.Count
            Members       = $members.Count
            Contributors  = $contrib.Count
            Viewers       = $viewers.Count
            Total         = $u.Count
            GroupGrants   = $groups.Count
            ServicePrincipals = $apps.Count
            ExternalUsers = $ext.Count
        }

        $add = {
            param($sev, $issue, $detail)
            [void]$findings.Add([PSCustomObject]@{
                Severity = $sev; Issue = $issue
                WorkspaceName = $ws.WorkspaceName; Detail = $detail
            })
        }
        if ($admins.Count -eq 0) {
            & $add "High" "No workspace admin" "Workspace has no Admin role assignment"
        }
        elseif ($admins.Count -eq 1) {
            & $add "Medium" "Single admin (bus factor)" ("Only admin: {0}" -f $admins[0].Name)
        }
        if ($ext.Count -gt 0) {
            & $add "Medium" "External / guest access" ("{0} external user(s)" -f $ext.Count)
        }
        if ($u.Count -ge $WidelySharedThreshold) {
            & $add "Low" "Widely shared" ("{0} principals have access" -f $u.Count)
        }
        if ($groups.Count -gt 0) {
            & $add "Info" "Access via security group" ("{0} group grant(s) - audit group membership separately" -f $groups.Count)
        }
    }

    $order = @{ High=0; Medium=1; Low=2; Info=3 }
    return [PSCustomObject]@{
        Workspaces = @($rows | Sort-Object WorkspaceName)
        Findings   = @($findings | Sort-Object { $order[$_.Severity] }, WorkspaceName)
        Summary    = [PSCustomObject]@{
            WorkspaceCount = @($rows).Count
            NoAdmin        = @($rows | Where-Object { $_.Admins -eq 0 }).Count
            SingleAdmin    = @($rows | Where-Object { $_.Admins -eq 1 }).Count
            WithExternal   = @($rows | Where-Object { $_.ExternalUsers -gt 0 }).Count
            WidelyShared   = @($rows | Where-Object { $_.Total -ge $WidelySharedThreshold }).Count
        }
    }
}

#endregion

#region Export

function Export-AccessAudit {
    <#
    .SYNOPSIS
        Writes the access audit to CSV and a markdown report under
        <GovernanceRoot>\Analysis_Output.
    #>
    param(
        [Parameter(Mandatory)]$Audit,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $out = Join-Path $GovernanceRoot "Analysis_Output"
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"

    if (@($Audit.Workspaces).Count -gt 0) {
        $Audit.Workspaces | Export-Csv -Path (Join-Path $out "AccessAudit_$ts.csv") -NoTypeInformation -Encoding UTF8
    }

    $md = Join-Path $out "AccessAudit_$ts.md"
    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"
    [void]$sb.Append("# Power BI Workspace Access Audit$nl$nl")
    [void]$sb.Append("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')$nl$nl")
    $s = $Audit.Summary
    [void]$sb.Append("Workspaces: $($s.WorkspaceCount)  |  No admin: $($s.NoAdmin)  |  Single admin: $($s.SingleAdmin)  |  With external users: $($s.WithExternal)  |  Widely shared: $($s.WidelyShared)$nl$nl")
    [void]$sb.Append("## Findings$nl$nl")
    if (@($Audit.Findings).Count -eq 0) {
        [void]$sb.Append("_No access risks flagged._$nl")
    } else {
        foreach ($f in $Audit.Findings) {
            [void]$sb.Append("- **[$($f.Severity)]** $($f.Issue) - $($f.WorkspaceName): $($f.Detail)$nl")
        }
    }
    $sb.ToString() | Set-Content -Path $md -Encoding UTF8

    Write-Host "Access audit written to: $out" -ForegroundColor Green
    return $md
}

#endregion

#region GUI

function Show-AccessAuditWindow {
    <#
    .SYNOPSIS
        Window to pull and review workspace access across the tenant.
    #>
    param([string]$GovernanceRoot = "")

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Workspace Access Audit"
    $form.Size = New-Object System.Drawing.Size(900, 640)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "Authentication (blank = interactive admin sign-in)"
    $grp.Location = New-Object System.Drawing.Point(12, 10)
    $grp.Size = New-Object System.Drawing.Size(870, 78)
    $form.Controls.Add($grp)

    $mkL = { param($t,$x,$y) $l=New-Object System.Windows.Forms.Label
        $l.Text=$t; $l.Location=New-Object System.Drawing.Point($x,$y)
        $l.Size=New-Object System.Drawing.Size(86,20); $grp.Controls.Add($l) }
    $mkB = { param($x,$y,$w,$pwd) $b=New-Object System.Windows.Forms.TextBox
        $b.Location=New-Object System.Drawing.Point($x,$y)
        $b.Size=New-Object System.Drawing.Size($w,20)
        if($pwd){$b.UseSystemPasswordChar=$true}; $grp.Controls.Add($b); $b }
    & $mkL "Tenant ID:" 10 22  | Out-Null; $txtTenant = & $mkB 100 20 230 $false
    & $mkL "Client ID:" 345 22 | Out-Null; $txtClient = & $mkB 435 20 230 $false
    & $mkL "Secret:" 10 48     | Out-Null; $txtSecret = & $mkB 100 46 230 $true

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Location = New-Object System.Drawing.Point(12, 96)
    $btnRun.Size = New-Object System.Drawing.Size(160, 30)
    $btnRun.Text = "Run Access Audit"
    $btnRun.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnRun)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Location = New-Object System.Drawing.Point(182, 96)
    $btnExport.Size = New-Object System.Drawing.Size(150, 30)
    $btnExport.Text = "Export Report"
    $btnExport.Enabled = $false
    $form.Controls.Add($btnExport)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(342, 100)
    $progress.Size = New-Object System.Drawing.Size(540, 22)
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 134)
    $output.Size = New-Object System.Drawing.Size(870, 420)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 562)
    $status.Size = New-Object System.Drawing.Size(870, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "Ready."
    $form.Controls.Add($status)

    $script:AccessAuditResult = $null

    $btnRun.Add_Click({
        $output.Clear()
        $btnRun.Enabled = $false
        $status.Text = "Connecting..."
        try {
            if (-not (Test-PbiApiConnection)) {
                Connect-PbiApi -TenantId $txtTenant.Text.Trim() `
                               -ClientId $txtClient.Text.Trim() `
                               -ClientSecret $txtSecret.Text.Trim() | Out-Null
            }
            $cb = {
                param($msg,$pct)
                $progress.Value = [Math]::Min(100,[Math]::Max(0,$pct))
                $status.Text = $msg
                [System.Windows.Forms.Application]::DoEvents()
            }
            $access = Get-WorkspaceAccess -ProgressCallback $cb
            $audit  = Get-AccessAudit -WorkspaceAccess $access
            $script:AccessAuditResult = $audit

            $s = $audit.Summary
            $output.AppendText("WORKSPACE ACCESS AUDIT`r`n")
            $output.AppendText(("=" * 80) + "`r`n")
            $output.AppendText(("Workspaces      : {0}`r`n" -f $s.WorkspaceCount))
            $output.AppendText(("No admin        : {0}`r`n" -f $s.NoAdmin))
            $output.AppendText(("Single admin    : {0}`r`n" -f $s.SingleAdmin))
            $output.AppendText(("With external   : {0}`r`n" -f $s.WithExternal))
            $output.AppendText(("Widely shared   : {0}`r`n`r`n" -f $s.WidelyShared))

            $output.AppendText(("FINDINGS ({0})`r`n" -f @($audit.Findings).Count))
            foreach ($f in $audit.Findings) {
                $output.AppendText(("  [{0,-6}] {1}`r`n" -f $f.Severity, $f.Issue))
                $output.AppendText(("           {0}: {1}`r`n" -f $f.WorkspaceName, $f.Detail))
            }
            $btnExport.Enabled = (@($audit.Workspaces).Count -gt 0)
            $status.Text = "Audit complete - $(@($audit.Findings).Count) finding(s)."
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
        if (-not $script:AccessAuditResult) { return }
        $root = $GovernanceRoot
        if ([string]::IsNullOrEmpty($root)) {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $root = $fb.SelectedPath
        }
        $path = Export-AccessAudit -Audit $script:AccessAuditResult -GovernanceRoot $root
        $status.Text = "Exported: $path"
        [System.Windows.Forms.MessageBox]::Show("Access audit written:`n$path","Export complete") | Out-Null
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
