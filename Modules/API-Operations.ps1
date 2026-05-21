# API-Operations.ps1
# Write-side and definition-download Power BI API operations, kept in their own
# window - separate from the read-only API Scanner.
#
#   * Bulk workspace access - add a service principal (or user / group) to many
#     workspaces in one pass via admin/groups/{id}/users. This is what lets the
#     toolkit's per-workspace APIs (refresh history, TMDL download) reach the
#     whole estate without granting access workspace by workspace.
#
#   * TMDL definition download - pull a semantic model's TMDL straight from the
#     Fabric REST API getDefinition endpoint. No .pbix, no pbi-tools and no
#     Power BI Desktop - the analysis features (best-practice analyzer,
#     Step 1-4) can then run on API-sourced TMDL.
#
# Depends on Connect-PbiApi / Invoke-PbiRestApi / Test-PbiApiConnection and the
# cached $script:PbiApiToken from API-Scanner.ps1, so it loads after it.

$script:FabricApiBase = "https://api.fabric.microsoft.com/v1"

#region Bulk workspace access

function Get-AllWorkspaceIds {
    # Lightweight list of all non-personal workspaces (admin/groups, no expand).
    if (-not (Test-PbiApiConnection)) { throw "Not connected to the Power BI API. Run Connect-PbiApi first." }
    $ids = @()
    $top = 5000; $skip = 0
    while ($true) {
        $path = 'admin/groups?$top=' + $top + '&$skip=' + $skip
        $resp = Invoke-PbiRestApi -Path $path
        $batch = @($resp.value)
        foreach ($w in $batch) {
            if ($w.type -ne 'PersonalGroup') {
                $ids += [PSCustomObject]@{ Id = $w.id; Name = $w.name }
            }
        }
        if ($batch.Count -lt $top) { break }
        $skip += $top
    }
    return @($ids)
}

function Add-PrincipalToWorkspace {
    <#
    .SYNOPSIS
        Adds one principal to one workspace (admin/groups/{id}/users).
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [ValidateSet('App','User','Group')][string]$PrincipalType = 'App',
        [ValidateSet('Admin','Member','Contributor','Viewer')][string]$AccessRight = 'Member'
    )
    $body = @{
        identifier           = $PrincipalId
        principalType        = $PrincipalType
        groupUserAccessRight = $AccessRight
    }
    Invoke-PbiRestApi -Path "admin/groups/$WorkspaceId/users" -Method POST -Body $body | Out-Null
}

function Add-WorkspaceAccessBulk {
    <#
    .SYNOPSIS
        Adds a principal to many workspaces. Returns a per-workspace result list
        (failures - e.g. principal already a member - are captured, not fatal).
    #>
    param(
        [Parameter(Mandatory)]$Workspaces,   # objects with .Id and .Name
        [Parameter(Mandatory)][string]$PrincipalId,
        [ValidateSet('App','User','Group')][string]$PrincipalType = 'App',
        [ValidateSet('Admin','Member','Contributor','Viewer')][string]$AccessRight = 'Member',
        [scriptblock]$ProgressCallback
    )
    $results = @()
    $list = @($Workspaces)
    $i = 0
    foreach ($w in $list) {
        $i++
        if ($ProgressCallback) {
            & $ProgressCallback ("Granting: $($w.Name)") ([int](($i / [Math]::Max(1,$list.Count)) * 100))
        }
        $ok = $true; $err = ""
        try {
            Add-PrincipalToWorkspace -WorkspaceId $w.Id -PrincipalId $PrincipalId `
                                     -PrincipalType $PrincipalType -AccessRight $AccessRight
        }
        catch { $ok = $false; $err = $_.Exception.Message }
        $results += [PSCustomObject]@{
            Workspace = $w.Name; WorkspaceId = $w.Id; Granted = $ok; Error = $err
        }
    }
    return @($results)
}

#endregion

#region TMDL definition download (Fabric getDefinition)

function Invoke-FabricRequest {
    <#
    .SYNOPSIS
        Calls a Fabric REST endpoint, transparently handling the 202
        long-running-operation pattern (poll the Location header until the
        operation succeeds, then fetch its result).
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        $Body
    )
    if (-not (Test-PbiApiConnection)) { throw "Not connected to the Power BI API. Run Connect-PbiApi first." }
    $headers = @{ Authorization = "Bearer $script:PbiApiToken" }
    $params  = @{ Uri = $Url; Method = $Method; Headers = $headers; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($Body -ne $null) {
        $params.Body = ($Body | ConvertTo-Json -Depth 8)
        $params.ContentType = 'application/json'
    }
    $resp = Invoke-WebRequest @params

    if ([int]$resp.StatusCode -eq 202) {
        $loc = $resp.Headers['Location']
        if ($loc -is [array]) { $loc = $loc[0] }
        if (-not $loc) { throw "Fabric LRO returned 202 with no Location header." }
        $status = 'Running'; $tries = 0
        while ($status -notin 'Succeeded','Failed' -and $tries -lt 80) {
            Start-Sleep -Seconds 3; $tries++
            $poll = Invoke-WebRequest -Uri $loc -Headers $headers -UseBasicParsing -ErrorAction Stop
            $status = ($poll.Content | ConvertFrom-Json).status
        }
        if ($status -ne 'Succeeded') { throw "Fabric operation did not succeed (status: $status)." }
        $resultUrl = $loc.TrimEnd('/') + "/result"
        $r = Invoke-WebRequest -Uri $resultUrl -Headers $headers -UseBasicParsing -ErrorAction Stop
        return ($r.Content | ConvertFrom-Json)
    }
    if ($resp.Content) { return ($resp.Content | ConvertFrom-Json) }
    return $null
}

function Get-SemanticModelTmdl {
    <#
    .SYNOPSIS
        Downloads one semantic model's TMDL definition into OutputFolder.
        Returns the number of definition parts written.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ModelId,
        [Parameter(Mandatory)][string]$OutputFolder
    )
    $url  = "$script:FabricApiBase/workspaces/$WorkspaceId/semanticModels/$ModelId/getDefinition?format=TMDL"
    $resp = Invoke-FabricRequest -Url $url -Method POST
    $parts = @($resp.definition.parts)
    if ($parts.Count -eq 0) { throw "No TMDL definition parts were returned." }

    if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }
    foreach ($p in $parts) {
        $target = Join-Path $OutputFolder $p.path
        $dir = Split-Path $target -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ($p.payloadType -eq 'InlineBase64') {
            [System.IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($p.payload))
        }
        else {
            $p.payload | Set-Content -Path $target -Encoding UTF8
        }
    }
    return $parts.Count
}

function Save-AllModelTmdl {
    <#
    .SYNOPSIS
        Downloads TMDL for every dataset that carries a WorkspaceId + DatasetId.
        Folders: <OutputRoot>\<workspace>\<model>\.
    #>
    param(
        [Parameter(Mandatory)]$Datasets,
        [Parameter(Mandatory)][string]$OutputRoot,
        [scriptblock]$ProgressCallback
    )
    $invalid = '[\\/:*?"<>|]'
    $results = @()
    $list = @($Datasets | Where-Object { $_.WorkspaceId -and $_.DatasetId })
    $i = 0
    foreach ($d in $list) {
        $i++
        if ($ProgressCallback) {
            & $ProgressCallback ("TMDL: $($d.DatasetName)") ([int](($i / [Math]::Max(1,$list.Count)) * 100))
        }
        $wsName = ([string]$d.WorkspaceName) -replace $invalid, '_'
        $dsName = ([string]$d.DatasetName)   -replace $invalid, '_'
        $folder = Join-Path (Join-Path $OutputRoot $wsName) $dsName
        $ok = $true; $err = ""; $count = 0
        try { $count = Get-SemanticModelTmdl -WorkspaceId $d.WorkspaceId -ModelId $d.DatasetId -OutputFolder $folder }
        catch { $ok = $false; $err = $_.Exception.Message }
        $results += [PSCustomObject]@{
            Model = $d.DatasetName; Workspace = $d.WorkspaceName
            Ok = $ok; Parts = $count; Error = $err
        }
    }
    return @($results)
}

#endregion

#region GUI

function Show-ApiOperationsWindow {
    <#
    .SYNOPSIS
        Dedicated window for the write-side / definition-download API
        operations. Kept separate from the API Scanner window on purpose.
    .PARAMETER Inventory
        Optional ConvertTo-PbiInventory output - supplies the workspace list and
        the datasets to download TMDL for. Falls back to $script:LastApiScan.
    #>
    param(
        [string]$GovernanceRoot = "",
        $Inventory = $null
    )
    if (-not $Inventory) { $Inventory = $script:LastApiScan }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - API Operations"
    $form.Size = New-Object System.Drawing.Size(900, 660)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    # --- shared authentication --------------------------------------------
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "Authentication (blank = interactive admin sign-in)"
    $grp.Location = New-Object System.Drawing.Point(12, 10)
    $grp.Size = New-Object System.Drawing.Size(862, 78)
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

    $ensureConn = {
        if (-not (Test-PbiApiConnection)) {
            Connect-PbiApi -TenantId $txtTenant.Text.Trim() `
                           -ClientId $txtClient.Text.Trim() `
                           -ClientSecret $txtSecret.Text.Trim() | Out-Null
        }
    }

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 96)
    $tabs.Size = New-Object System.Drawing.Size(862, 514)
    $tabs.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($tabs)

    # ===================== Tab 1: Bulk workspace access ===================
    $tab1 = New-Object System.Windows.Forms.TabPage
    $tab1.Text = "Bulk Workspace Access"
    $tabs.Controls.Add($tab1)

    $t1info = New-Object System.Windows.Forms.Label
    $t1info.Location = New-Object System.Drawing.Point(12, 12)
    $t1info.Size = New-Object System.Drawing.Size(820, 34)
    $t1info.Text = "Adds a principal (typically this toolkit's service principal) to every " +
                   "workspace, so per-workspace APIs reach the whole estate."
    $tab1.Controls.Add($t1info)

    $t1 = New-Object System.Windows.Forms.Label
    $t1.Location = New-Object System.Drawing.Point(12, 52); $t1.Size = New-Object System.Drawing.Size(150,20)
    $t1.Text = "Principal (object/app ID):"; $tab1.Controls.Add($t1)
    $txtPrincipal = New-Object System.Windows.Forms.TextBox
    $txtPrincipal.Location = New-Object System.Drawing.Point(168, 50)
    $txtPrincipal.Size = New-Object System.Drawing.Size(320, 20)
    $tab1.Controls.Add($txtPrincipal)

    $lblType = New-Object System.Windows.Forms.Label
    $lblType.Location = New-Object System.Drawing.Point(12, 82); $lblType.Size = New-Object System.Drawing.Size(150,20)
    $lblType.Text = "Principal type:"; $tab1.Controls.Add($lblType)
    $cmbType = New-Object System.Windows.Forms.ComboBox
    $cmbType.Location = New-Object System.Drawing.Point(168, 80)
    $cmbType.Size = New-Object System.Drawing.Size(140, 20)
    $cmbType.DropDownStyle = "DropDownList"
    [void]$cmbType.Items.AddRange(@("App","User","Group")); $cmbType.SelectedIndex = 0
    $tab1.Controls.Add($cmbType)

    $lblRight = New-Object System.Windows.Forms.Label
    $lblRight.Location = New-Object System.Drawing.Point(330, 82); $lblRight.Size = New-Object System.Drawing.Size(90,20)
    $lblRight.Text = "Access right:"; $tab1.Controls.Add($lblRight)
    $cmbRight = New-Object System.Windows.Forms.ComboBox
    $cmbRight.Location = New-Object System.Drawing.Point(424, 80)
    $cmbRight.Size = New-Object System.Drawing.Size(140, 20)
    $cmbRight.DropDownStyle = "DropDownList"
    [void]$cmbRight.Items.AddRange(@("Member","Admin","Contributor","Viewer")); $cmbRight.SelectedIndex = 0
    $tab1.Controls.Add($cmbRight)

    $btnGrant = New-Object System.Windows.Forms.Button
    $btnGrant.Location = New-Object System.Drawing.Point(12, 116)
    $btnGrant.Size = New-Object System.Drawing.Size(230, 30)
    $btnGrant.Text = "Grant to ALL workspaces"
    $btnGrant.BackColor = [System.Drawing.Color]::Khaki
    $tab1.Controls.Add($btnGrant)

    $prog1 = New-Object System.Windows.Forms.ProgressBar
    $prog1.Location = New-Object System.Drawing.Point(252, 119)
    $prog1.Size = New-Object System.Drawing.Size(580, 22)
    $prog1.Anchor = "Top,Left,Right"
    $tab1.Controls.Add($prog1)

    $out1 = New-Object System.Windows.Forms.RichTextBox
    $out1.Location = New-Object System.Drawing.Point(12, 156)
    $out1.Size = New-Object System.Drawing.Size(820, 300)
    $out1.Font = New-Object System.Drawing.Font("Consolas", 9)
    $out1.ReadOnly = $true
    $out1.Anchor = "Top,Bottom,Left,Right"
    $tab1.Controls.Add($out1)

    $btnGrant.Add_Click({
        $principalId = $txtPrincipal.Text.Trim()
        if ([string]::IsNullOrEmpty($principalId)) {
            [System.Windows.Forms.MessageBox]::Show("Enter the principal's object / app ID.","Required") | Out-Null
            return
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Add principal`n$principalId`nto ALL workspaces as $($cmbRight.SelectedItem)?",
            "Confirm bulk grant",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $btnGrant.Enabled = $false
        $out1.Clear()
        try {
            & $ensureConn
            $ws = if ($Inventory -and @($Inventory.Workspaces).Count -gt 0) {
                @($Inventory.Workspaces | ForEach-Object {
                    [PSCustomObject]@{ Id = $_.WorkspaceId; Name = $_.WorkspaceName } })
            } else { Get-AllWorkspaceIds }
            $out1.AppendText("Granting access to $($ws.Count) workspace(s)...`r`n`r`n")
            $cb = { param($m,$p) $prog1.Value=[Math]::Min(100,[Math]::Max(0,$p))
                    [System.Windows.Forms.Application]::DoEvents() }
            $res = Add-WorkspaceAccessBulk -Workspaces $ws -PrincipalId $principalId `
                       -PrincipalType $cmbType.SelectedItem -AccessRight $cmbRight.SelectedItem -ProgressCallback $cb
            $okN = @($res | Where-Object { $_.Granted }).Count
            foreach ($r in $res) {
                if ($r.Granted) { $out1.AppendText(("  OK    {0}`r`n" -f $r.Workspace)) }
                else { $out1.AppendText(("  FAIL  {0}  -  {1}`r`n" -f $r.Workspace, $r.Error)) }
            }
            $out1.AppendText(("`r`nGranted on {0} of {1} workspace(s)." -f $okN, $res.Count))
        }
        catch { $out1.AppendText("`r`nERROR: $($_.Exception.Message)`r`n") }
        finally { $btnGrant.Enabled = $true; $prog1.Value = 0 }
    })

    # ===================== Tab 2: TMDL download ===========================
    $tab2 = New-Object System.Windows.Forms.TabPage
    $tab2.Text = "TMDL Download"
    $tabs.Controls.Add($tab2)

    $t2info = New-Object System.Windows.Forms.Label
    $t2info.Location = New-Object System.Drawing.Point(12, 12)
    $t2info.Size = New-Object System.Drawing.Size(820, 50)
    $t2info.Text = "Downloads each model's TMDL definition straight from the Fabric API " +
                   "(getDefinition) - no .pbix, no pbi-tools, no Power BI Desktop. Needs a " +
                   "prior API scan for the model list, and workspace access for the principal."
    $tab2.Controls.Add($t2info)

    $btnTmdl = New-Object System.Windows.Forms.Button
    $btnTmdl.Location = New-Object System.Drawing.Point(12, 68)
    $btnTmdl.Size = New-Object System.Drawing.Size(290, 30)
    $btnTmdl.Text = "Download TMDL for all governed models"
    $btnTmdl.BackColor = [System.Drawing.Color]::Khaki
    $tab2.Controls.Add($btnTmdl)

    $prog2 = New-Object System.Windows.Forms.ProgressBar
    $prog2.Location = New-Object System.Drawing.Point(312, 71)
    $prog2.Size = New-Object System.Drawing.Size(520, 22)
    $prog2.Anchor = "Top,Left,Right"
    $tab2.Controls.Add($prog2)

    $out2 = New-Object System.Windows.Forms.RichTextBox
    $out2.Location = New-Object System.Drawing.Point(12, 108)
    $out2.Size = New-Object System.Drawing.Size(820, 348)
    $out2.Font = New-Object System.Drawing.Font("Consolas", 9)
    $out2.ReadOnly = $true
    $out2.Anchor = "Top,Bottom,Left,Right"
    $tab2.Controls.Add($out2)

    $btnTmdl.Add_Click({
        if (-not $Inventory -or @($Inventory.Datasets).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Run an API tenant scan first - the model list comes from the scan inventory.",
                "No inventory") | Out-Null
            return
        }
        $root = $GovernanceRoot
        if ([string]::IsNullOrEmpty($root)) {
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($fb.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $root = $fb.SelectedPath
        }
        $btnTmdl.Enabled = $false
        $out2.Clear()
        try {
            & $ensureConn
            $outRoot = Join-Path (Join-Path $root "Analysis_Output") "TMDL"
            $out2.AppendText("Downloading TMDL for $(@($Inventory.Datasets).Count) model(s) -> $outRoot`r`n`r`n")
            $cb = { param($m,$p) $prog2.Value=[Math]::Min(100,[Math]::Max(0,$p))
                    [System.Windows.Forms.Application]::DoEvents() }
            $res = Save-AllModelTmdl -Datasets $Inventory.Datasets -OutputRoot $outRoot -ProgressCallback $cb
            foreach ($r in $res) {
                if ($r.Ok) { $out2.AppendText(("  OK    {0}  ({1} parts)`r`n" -f $r.Model, $r.Parts)) }
                else { $out2.AppendText(("  FAIL  {0}  -  {1}`r`n" -f $r.Model, $r.Error)) }
            }
            $okN = @($res | Where-Object { $_.Ok }).Count
            $out2.AppendText(("`r`nDownloaded {0} of {1} model(s)." -f $okN, $res.Count))
        }
        catch { $out2.AppendText("`r`nERROR: $($_.Exception.Message)`r`n") }
        finally { $btnTmdl.Enabled = $true; $prog2.Value = 0 }
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
