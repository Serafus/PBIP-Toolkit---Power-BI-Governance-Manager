# Lineage-Graph.ps1
# Builds a governance-wide lineage graph for the Power BI estate and exports it
# as an interactive, self-contained HTML view (plus graph.json and a markdown
# report). Inspired by the "graphify" knowledge-graph approach, adapted for
# Power BI governance: the whole estate is shown as ONE interconnected graph,
# not a per-model silo.
#
# The connective tissue is deliberate:
#   * SHARED DATA SOURCES  - one node per physical source (deduplicated by
#     connection details), so every model drawing on the same database/file is
#     visibly linked through it, even across different workspaces.
#   * SHARED WORKSPACES    - a workspace node ties together every model, report
#     and dataflow it contains.
#
# Node types : Workspace, DataSource, Dataset, Report, Dataflow
# Edge kinds : contains (workspace->item), feeds (source->dataset),
#              powers (dataset->report), upstream (dataset->dataset)
#
# Input is the inventory from ConvertTo-PbiInventory (API-Scanner.ps1), which
# must have been produced with datasourceDetails=true (the default).

#region Graph construction

function Get-LineageSourceKey {
    # Normalised identity for a datasource so the SAME physical source collapses
    # to a single node regardless of how many datasets reference it.
    param($Source)
    $parts = @($Source.Type, $Source.Server, $Source.Database, $Source.Url, $Source.Path) |
        ForEach-Object { if ($_) { ([string]$_).Trim().ToLower() } else { "" } }
    $key = ($parts -join '|')
    # If there is no connection detail at all, fall back to the raw id so
    # unrelated detail-less sources do not all merge into one node.
    if (($parts[1..4] -join '') -eq '') { $key = "$($parts[0])|id:$($Source.DatasourceId)" }
    return $key
}

function Build-LineageGraph {
    <#
    .SYNOPSIS
        Builds the estate-wide lineage graph from a Power BI API inventory.
    .PARAMETER Inventory
        Output of ConvertTo-PbiInventory.
    .PARAMETER LocalScan
        Optional Scan-GovernanceStructure output - used only to mark which
        datasets also exist in the local Governance folder.
    .OUTPUTS
        PSCustomObject with .Nodes and .Links arrays.
    #>
    param(
        [Parameter(Mandatory)]$Inventory,
        $LocalScan = @()
    )

    $nodes = [ordered]@{}   # id -> node
    $links = @()

    function _add($id, $type, $label, $group, $meta) {
        if (-not $nodes.Contains($id)) {
            $nodes[$id] = [PSCustomObject]@{
                id = $id; type = $type; label = $label
                group = $group; degree = 0; meta = $meta
            }
        }
    }

    # --- Workspaces --------------------------------------------------------
    foreach ($ws in @($Inventory.Workspaces)) {
        if (-not $ws.WorkspaceId) { continue }
        _add "ws:$($ws.WorkspaceId)" "Workspace" $ws.WorkspaceName $ws.WorkspaceName @{
            datasets = $ws.DatasetCount; reports = $ws.ReportCount
            onDedicated = [bool]$ws.IsOnDedicated
        }
    }

    # --- Data sources (deduplicated) --------------------------------------
    $sourceIdToNode = @{}   # raw DatasourceId -> collapsed node id
    foreach ($src in @($Inventory.DataSources)) {
        $key   = Get-LineageSourceKey -Source $src
        $nodeId = "src:$key"
        $detail = if ($src.Detail) { $src.Detail } else { "(no connection detail)" }
        _add $nodeId "DataSource" ("{0}: {1}" -f $src.Type, $detail) "(data sources)" @{
            sourceType = $src.Type; detail = $detail; gateway = $src.GatewayId
        }
        if ($src.DatasourceId) { $sourceIdToNode[$src.DatasourceId] = $nodeId }
    }

    # --- Datasets ----------------------------------------------------------
    foreach ($ds in @($Inventory.Datasets)) {
        if (-not $ds.DatasetId) { continue }
        $endorse = if ([string]::IsNullOrEmpty($ds.Endorsement)) { "None" } else { $ds.Endorsement }
        $dsNode  = "ds:$($ds.DatasetId)"
        _add $dsNode "Dataset" $ds.DatasetName $ds.WorkspaceName @{
            owner = $ds.ConfiguredBy; endorsement = $endorse
            workspace = $ds.WorkspaceName; tables = $ds.TableCount
        }
        if ($ds.WorkspaceId) {
            $links += [PSCustomObject]@{ source = "ws:$($ds.WorkspaceId)"; target = $dsNode; kind = "contains" }
        }
        foreach ($instId in @($ds.DatasourceInstanceIds)) {
            if ($sourceIdToNode.ContainsKey($instId)) {
                $links += [PSCustomObject]@{ source = $sourceIdToNode[$instId]; target = $dsNode; kind = "feeds" }
            }
        }
        foreach ($up in @($ds.UpstreamDatasets)) {
            $links += [PSCustomObject]@{ source = "ds:$up"; target = $dsNode; kind = "upstream" }
        }
    }

    # --- Reports -----------------------------------------------------------
    foreach ($rp in @($Inventory.Reports)) {
        if (-not $rp.ReportId) { continue }
        $rpNode = "rp:$($rp.ReportId)"
        _add $rpNode "Report" $rp.ReportName $rp.WorkspaceName @{
            workspace = $rp.WorkspaceName; reportType = $rp.ReportType
        }
        if ($rp.WorkspaceId) {
            $links += [PSCustomObject]@{ source = "ws:$($rp.WorkspaceId)"; target = $rpNode; kind = "contains" }
        }
        if ($rp.DatasetId) {
            $links += [PSCustomObject]@{ source = "ds:$($rp.DatasetId)"; target = $rpNode; kind = "powers" }
        }
    }

    # --- Dataflows ---------------------------------------------------------
    foreach ($df in @($Inventory.Dataflows)) {
        if (-not $df.DataflowId) { continue }
        $dfNode = "df:$($df.DataflowId)"
        _add $dfNode "Dataflow" $df.DataflowName $df.WorkspaceName @{ workspace = $df.WorkspaceName }
        if ($df.WorkspaceId) {
            $links += [PSCustomObject]@{ source = "ws:$($df.WorkspaceId)"; target = $dfNode; kind = "contains" }
        }
    }

    # --- Mark datasets that also exist locally -----------------------------
    foreach ($m in @($LocalScan)) {
        if ($m.DatasetId -and $nodes.Contains("ds:$($m.DatasetId)")) {
            $nodes["ds:$($m.DatasetId)"].meta.localPbip = [bool]$m.PbipExists
        }
    }

    # --- Keep only links whose endpoints exist; compute degree -------------
    $validLinks = @()
    foreach ($l in $links) {
        if ($nodes.Contains($l.source) -and $nodes.Contains($l.target)) {
            $validLinks += $l
            $nodes[$l.source].degree++
            $nodes[$l.target].degree++
        }
    }

    return [PSCustomObject]@{
        Nodes = @($nodes.Values)
        Links = @($validLinks)
    }
}

#endregion

#region Statistics / report

function Get-LineageStats {
    <#
    .SYNOPSIS
        Derives governance highlights from a lineage graph: god nodes, sources
        shared across workspaces, and orphaned datasets.
    #>
    param([Parameter(Mandatory)]$Graph)

    $nodes = @($Graph.Nodes)
    $links = @($Graph.Links)
    $byId  = @{}
    foreach ($n in $nodes) { $byId[$n.id] = $n }

    $typeCounts = $nodes | Group-Object type |
        ForEach-Object { [PSCustomObject]@{ Type = $_.Name; Count = $_.Count } }

    # God nodes - the highest-degree nodes; failures here cascade widest.
    $godNodes = $nodes | Sort-Object degree -Descending | Select-Object -First 8 |
        ForEach-Object { [PSCustomObject]@{ Label = $_.label; Type = $_.type; Degree = $_.degree } }

    # Shared sources - a DataSource feeding 2+ datasets, with the count of
    # DISTINCT workspaces those datasets sit in (cross-workspace reach).
    $feeds = $links | Where-Object { $_.kind -eq "feeds" }
    $sharedSources = @()
    foreach ($srcNode in ($nodes | Where-Object { $_.type -eq "DataSource" })) {
        $fed = @($feeds | Where-Object { $_.source -eq $srcNode.id })
        if ($fed.Count -ge 2) {
            $wsSet = @{}
            foreach ($f in $fed) {
                $dsn = $byId[$f.target]
                if ($dsn -and $dsn.meta.workspace) { $wsSet[$dsn.meta.workspace] = $true }
            }
            $sharedSources += [PSCustomObject]@{
                Source        = $srcNode.label
                DatasetsFed   = $fed.Count
                WorkspaceSpan = $wsSet.Keys.Count
            }
        }
    }
    $sharedSources = @($sharedSources | Sort-Object DatasetsFed -Descending)

    # Orphan datasets - no known upstream source.
    $datasetsWithSource = @{}
    foreach ($f in $feeds) { $datasetsWithSource[$f.target] = $true }
    $upstream = $links | Where-Object { $_.kind -eq "upstream" }
    foreach ($u in $upstream) { $datasetsWithSource[$u.target] = $true }
    $orphans = @($nodes | Where-Object {
        $_.type -eq "Dataset" -and -not $datasetsWithSource.ContainsKey($_.id)
    } | ForEach-Object { [PSCustomObject]@{ Dataset = $_.label; Workspace = $_.meta.workspace } })

    return [PSCustomObject]@{
        NodeCount      = $nodes.Count
        LinkCount      = $links.Count
        TypeCounts     = @($typeCounts)
        GodNodes       = @($godNodes)
        SharedSources  = $sharedSources
        CrossWorkspaceSources = @($sharedSources | Where-Object { $_.WorkspaceSpan -ge 2 })
        OrphanDatasets = $orphans
    }
}

function ConvertTo-LineageReport {
    # Renders a graphify-style markdown report from the graph + stats.
    param([Parameter(Mandatory)]$Graph, [Parameter(Mandatory)]$Stats)
    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"
    [void]$sb.Append("# Power BI Governance - Lineage Report$nl$nl")
    [void]$sb.Append("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')$nl$nl")
    [void]$sb.Append("The estate as one graph: **$($Stats.NodeCount) nodes**, **$($Stats.LinkCount) links**.$nl$nl")

    [void]$sb.Append("## Composition$nl$nl")
    foreach ($t in $Stats.TypeCounts) { [void]$sb.Append("- $($t.Type): $($t.Count)$nl") }
    [void]$sb.Append($nl)

    [void]$sb.Append("## God nodes (widest blast radius)$nl$nl")
    [void]$sb.Append("The most-connected nodes - if one breaks, the impact spreads furthest.$nl$nl")
    foreach ($g in $Stats.GodNodes) {
        [void]$sb.Append("- **$($g.Label)** ($($g.Type)) - $($g.Degree) connections$nl")
    }
    [void]$sb.Append($nl)

    [void]$sb.Append("## Shared data sources$nl$nl")
    [void]$sb.Append("Sources feeding more than one model - the real interconnection of the estate.$nl$nl")
    if (@($Stats.SharedSources).Count -eq 0) {
        [void]$sb.Append("_None - no source is used by two or more models in the scan._$nl")
    } else {
        foreach ($s in $Stats.SharedSources) {
            [void]$sb.Append("- **$($s.Source)** - feeds $($s.DatasetsFed) models across $($s.WorkspaceSpan) workspace(s)$nl")
        }
    }
    [void]$sb.Append($nl)

    [void]$sb.Append("## Cross-workspace sources (highest governance risk)$nl$nl")
    [void]$sb.Append("A change to one of these ripples across workspace boundaries.$nl$nl")
    if (@($Stats.CrossWorkspaceSources).Count -eq 0) {
        [void]$sb.Append("_None detected._$nl")
    } else {
        foreach ($s in $Stats.CrossWorkspaceSources) {
            [void]$sb.Append("- **$($s.Source)** - spans $($s.WorkspaceSpan) workspaces, $($s.DatasetsFed) models$nl")
        }
    }
    [void]$sb.Append($nl)

    [void]$sb.Append("## Orphan datasets$nl$nl")
    [void]$sb.Append("Models with no data source the Scanner API could see - check gateway/credential visibility.$nl$nl")
    if ($Stats.OrphanDatasets.Count -eq 0) {
        [void]$sb.Append("_None._$nl")
    } else {
        foreach ($o in $Stats.OrphanDatasets) {
            [void]$sb.Append("- $($o.Dataset) ($($o.Workspace))$nl")
        }
    }
    return $sb.ToString()
}

#endregion

#region HTML export

# Self-contained interactive graph. Single-quoted here-string: nothing is
# interpolated, so JS may freely use $ and backticks. Data is injected by
# replacing the /*GRAPH_DATA*/ and /*META_DATA*/ tokens.
$script:LineageHtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Power BI Governance - Lineage Graph</title>
<style>
  html,body{margin:0;height:100%;font-family:Segoe UI,Arial,sans-serif;background:#f4f5f7;color:#222}
  #bar{position:fixed;top:0;left:0;right:0;height:48px;background:#2b3a55;color:#fff;
       display:flex;align-items:center;gap:14px;padding:0 14px;z-index:10}
  #bar b{font-size:15px}
  #bar .stat{font-size:12px;opacity:.85}
  #side{position:fixed;top:48px;right:0;width:300px;bottom:0;background:#fff;
        border-left:1px solid #d4d7dd;overflow:auto;padding:12px;box-sizing:border-box;font-size:13px}
  #side h3{margin:6px 0;font-size:14px}
  #legend span{display:inline-block;margin:2px 8px 2px 0;font-size:12px}
  #legend i{display:inline-block;width:11px;height:11px;border-radius:50%;margin-right:4px;vertical-align:-1px}
  #tools{position:fixed;top:56px;left:10px;z-index:9;background:#fff;border:1px solid #d4d7dd;
         border-radius:6px;padding:8px 10px;font-size:12px;max-width:230px}
  #tools label{display:block;margin:3px 0;cursor:pointer}
  #tools input[type=text]{width:100%;box-sizing:border-box;margin-bottom:6px;padding:4px}
  canvas{display:block;position:fixed;top:48px;left:0;bottom:0}
  .muted{color:#777}
  button{cursor:pointer;border:1px solid #b9c0cc;background:#eef0f3;border-radius:4px;padding:3px 8px}
</style>
</head>
<body>
<div id="bar">
  <b>PBIP Toolkit &middot; Lineage Graph</b>
  <span class="stat" id="counts"></span>
  <span style="flex:1"></span>
  <span class="stat">drag nodes &middot; scroll to zoom &middot; click a node to inspect</span>
</div>
<div id="tools">
  <input type="text" id="search" placeholder="search nodes...">
  <div id="filters"></div>
  <button id="reset">Reset view</button>
</div>
<div id="side"><h3>Lineage</h3>
  <div id="legend"></div>
  <p class="muted">Click any node to see its connections. Shared data sources
  link models across workspaces &mdash; that is the governance picture.</p>
  <div id="detail"></div>
</div>
<canvas id="c"></canvas>
<script>
const GRAPH = /*GRAPH_DATA*/;
const META  = /*META_DATA*/;
const COL = {Workspace:"#6b5b95",DataSource:"#d9822b",Dataset:"#3a7ca5",Report:"#2e8b57",Dataflow:"#8a6d3b"};
const EDGECOL = {contains:"#c7ccd4",feeds:"#d9822b",powers:"#2e8b57",upstream:"#3a7ca5"};

const cv = document.getElementById("c"), ctx = cv.getContext("2d");
let W,H;
function resize(){ W=cv.width=window.innerWidth-300; H=cv.height=window.innerHeight-48; }
window.addEventListener("resize",resize); resize();

const nodes = GRAPH.Nodes || GRAPH.nodes || [];
const rawLinks = GRAPH.Links || GRAPH.links || [];
const idx = {};
nodes.forEach((n,i)=>{ idx[n.id]=i;
  n.x=W/2+(Math.random()-.5)*W*0.7; n.y=H/2+(Math.random()-.5)*H*0.7; n.vx=0; n.vy=0; });
const links = rawLinks.map(l=>({s:idx[l.source],t:idx[l.target],kind:l.kind}))
                      .filter(l=>l.s!=null&&l.t!=null);
const adj = nodes.map(()=>[]);
links.forEach(l=>{ adj[l.s].push(l.t); adj[l.t].push(l.s); });

document.getElementById("counts").textContent =
  nodes.length+" nodes · "+links.length+" links";

// legend + type filters
const visible = {}; const types=[...new Set(nodes.map(n=>n.type))];
const leg=document.getElementById("legend"), fil=document.getElementById("filters");
types.forEach(t=>{ visible[t]=true;
  leg.innerHTML+='<span><i style="background:'+(COL[t]||"#999")+'"></i>'+t+'</span>';
  const lb=document.createElement("label");
  lb.innerHTML='<input type="checkbox" checked data-t="'+t+'"> '+t;
  fil.appendChild(lb);
});
fil.addEventListener("change",e=>{ if(e.target.dataset.t){ visible[e.target.dataset.t]=e.target.checked; }});

let search="";
document.getElementById("search").addEventListener("input",e=>{ search=e.target.value.toLowerCase(); });

// view transform
let scale=1, ox=0, oy=0;
function reset(){ scale=1; ox=0; oy=0; alpha=1; }
document.getElementById("reset").addEventListener("click",reset);
cv.addEventListener("wheel",e=>{ e.preventDefault();
  const f=e.deltaY<0?1.1:0.9; const mx=e.offsetX,my=e.offsetY;
  ox=mx-(mx-ox)*f; oy=my-(my-oy)*f; scale*=f;
},{passive:false});

const R = n => 4 + Math.sqrt(n.degree||0)*2.4;
function nodeVisible(n){ return visible[n.type]; }

// simulation
let alpha=1;
function step(){
  if(alpha<0.02) return;
  for(let i=0;i<nodes.length;i++){
    const a=nodes[i]; if(!nodeVisible(a))continue;
    for(let j=i+1;j<nodes.length;j++){
      const b=nodes[j]; if(!nodeVisible(b))continue;
      let dx=a.x-b.x, dy=a.y-b.y, d2=dx*dx+dy*dy||0.01;
      if(d2>360000) continue;
      const f=2600/d2;
      const d=Math.sqrt(d2); dx/=d; dy/=d;
      a.vx+=dx*f; a.vy+=dy*f; b.vx-=dx*f; b.vy-=dy*f;
    }
  }
  links.forEach(l=>{
    const a=nodes[l.s], b=nodes[l.t];
    if(!nodeVisible(a)||!nodeVisible(b))return;
    let dx=b.x-a.x, dy=b.y-a.y, d=Math.sqrt(dx*dx+dy*dy)||0.01;
    const ideal=l.kind==="feeds"?150:95;
    const f=(d-ideal)/d*0.045*alpha;
    dx*=f; dy*=f;
    a.vx+=dx; a.vy+=dy; b.vx-=dx; b.vy-=dy;
  });
  nodes.forEach(n=>{
    if(!nodeVisible(n))return;
    n.vx+=(W/2-n.x)*0.0015; n.vy+=(H/2-n.y)*0.0015;
    if(n===dragged)return;
    n.x+=n.vx*0.85; n.y+=n.vy*0.85; n.vx*=0.82; n.vy*=0.82;
  });
  alpha*=0.992;
}

let sel=null, dragged=null, hover=null;
function draw(){
  ctx.setTransform(1,0,0,1,0,0); ctx.clearRect(0,0,W,H);
  ctx.setTransform(scale,0,0,scale,ox,oy);
  const hot = sel!=null ? new Set([sel,...adj[sel]]) : null;
  // edges
  links.forEach(l=>{
    const a=nodes[l.s], b=nodes[l.t];
    if(!nodeVisible(a)||!nodeVisible(b))return;
    const on = !hot || (hot.has(l.s)&&hot.has(l.t));
    ctx.strokeStyle=EDGECOL[l.kind]||"#ccc";
    ctx.globalAlpha = on?0.75:0.07;
    ctx.lineWidth=(l.kind==="feeds"?1.6:1)/scale;
    ctx.beginPath(); ctx.moveTo(a.x,a.y); ctx.lineTo(b.x,b.y); ctx.stroke();
  });
  ctx.globalAlpha=1;
  // nodes
  nodes.forEach((n,i)=>{
    if(!nodeVisible(n))return;
    const r=R(n);
    const match = search && n.label && n.label.toLowerCase().includes(search);
    const dim = (hot && !hot.has(i)) || (search && !match);
    ctx.globalAlpha = dim?0.12:1;
    ctx.beginPath(); ctx.arc(n.x,n.y,r,0,6.283);
    ctx.fillStyle=COL[n.type]||"#999"; ctx.fill();
    if(match){ ctx.lineWidth=3/scale; ctx.strokeStyle="#e8b400"; ctx.stroke(); }
    if(i===sel){ ctx.lineWidth=2.5/scale; ctx.strokeStyle="#111"; ctx.stroke(); }
    if(r*scale>9 || i===sel || i===hover || match){
      ctx.globalAlpha = dim?0.3:1;
      ctx.fillStyle="#222"; ctx.font=(11/scale)+"px Segoe UI";
      ctx.fillText(n.label||"", n.x+r+2, n.y+3);
    }
  });
  ctx.globalAlpha=1;
}
function loop(){ step(); draw(); requestAnimationFrame(loop); }
loop();

// picking
function pick(mx,my){
  const x=(mx-ox)/scale, y=(my-oy)/scale;
  for(let i=nodes.length-1;i>=0;i--){
    const n=nodes[i]; if(!nodeVisible(n))continue;
    const r=R(n)+3;
    if((n.x-x)**2+(n.y-y)**2<=r*r) return i;
  }
  return null;
}
let panning=false, panx, pany;
cv.addEventListener("mousedown",e=>{
  const i=pick(e.offsetX,e.offsetY);
  if(i!=null){ dragged=i; sel=i; showDetail(i); }
  else { panning=true; panx=e.offsetX-ox; pany=e.offsetY-oy; }
});
cv.addEventListener("mousemove",e=>{
  hover=pick(e.offsetX,e.offsetY);
  cv.style.cursor = hover!=null?"pointer":(panning?"grabbing":"default");
  if(dragged!=null){
    nodes[dragged].x=(e.offsetX-ox)/scale; nodes[dragged].y=(e.offsetY-oy)/scale;
    nodes[dragged].vx=0; nodes[dragged].vy=0; alpha=Math.max(alpha,0.3);
  } else if(panning){ ox=e.offsetX-panx; oy=e.offsetY-pany; }
});
window.addEventListener("mouseup",()=>{ dragged=null; panning=false; });

function showDetail(i){
  const n=nodes[i];
  const ns=adj[i].map(j=>nodes[j]);
  const grp=t=>ns.filter(x=>x.type===t).map(x=>"<li>"+esc(x.label)+"</li>").join("");
  let h="<h3>"+esc(n.label)+"</h3>";
  h+='<p><b>'+n.type+'</b> &middot; '+n.degree+' connections</p>';
  if(n.meta){ for(const k in n.meta){ if(n.meta[k]!==null&&n.meta[k]!=="")
    h+='<div class="muted">'+k+': '+esc(String(n.meta[k]))+'</div>'; } }
  ["Workspace","DataSource","Dataset","Report","Dataflow"].forEach(t=>{
    const g=grp(t); if(g) h+='<p><b>'+t+'s</b><ul>'+g+'</ul></p>';
  });
  document.getElementById("detail").innerHTML=h;
}
function esc(s){ return String(s).replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c])); }
</script>
</body>
</html>
'@

function Export-LineageGraph {
    <#
    .SYNOPSIS
        Writes graph.json, lineage.html (interactive) and LINEAGE_REPORT.md to
        <GovernanceRoot>\Analysis_Output\Lineage\. Returns the HTML path.
    #>
    param(
        [Parameter(Mandatory)]$Graph,
        [Parameter(Mandatory)]$Stats,
        [Parameter(Mandatory)][string]$GovernanceRoot
    )
    $dir = Join-Path (Join-Path $GovernanceRoot "Analysis_Output") "Lineage"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $jsonPath = Join-Path $dir "graph.json"
    $htmlPath = Join-Path $dir "lineage.html"
    $mdPath   = Join-Path $dir "LINEAGE_REPORT.md"

    $graphJson = $Graph | ConvertTo-Json -Depth 8
    $graphJson | Set-Content -Path $jsonPath -Encoding UTF8

    $metaJson = @{
        generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        nodes = $Stats.NodeCount; links = $Stats.LinkCount
    } | ConvertTo-Json -Compress

    $html = $script:LineageHtmlTemplate.Replace('/*GRAPH_DATA*/', $graphJson).Replace('/*META_DATA*/', $metaJson)
    $html | Set-Content -Path $htmlPath -Encoding UTF8

    (ConvertTo-LineageReport -Graph $Graph -Stats $Stats) | Set-Content -Path $mdPath -Encoding UTF8

    Write-Host "Lineage exported to: $dir" -ForegroundColor Green
    return $htmlPath
}

#endregion

#region GUI

function Show-LineageWindow {
    <#
    .SYNOPSIS
        Window to build and open the estate-wide lineage graph.
    .PARAMETER Inventory
        ConvertTo-PbiInventory output. If $null, falls back to $script:LastApiScan.
    .PARAMETER GovernanceRoot
        Governance root - exports land under Analysis_Output\Lineage.
    .PARAMETER LocalScan
        Optional folder-scan results, used to mark locally-held models.
    #>
    param(
        $Inventory = $null,
        [string]$GovernanceRoot = "",
        $LocalScan = @()
    )

    if (-not $Inventory) { $Inventory = $script:LastApiScan }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PBIP Toolkit - Lineage Graph"
    $form.Size = New-Object System.Drawing.Size(780, 600)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(740, 36)
    $lbl.Text = "Builds one interconnected graph of the whole estate - data sources, " +
                "datasets, reports and workspaces. Shared sources link models across workspaces."
    $form.Controls.Add($lbl)

    $btnBuild = New-Object System.Windows.Forms.Button
    $btnBuild.Location = New-Object System.Drawing.Point(12, 52)
    $btnBuild.Size = New-Object System.Drawing.Size(170, 32)
    $btnBuild.Text = "Build Lineage Graph"
    $btnBuild.BackColor = [System.Drawing.Color]::LightGreen
    $form.Controls.Add($btnBuild)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Location = New-Object System.Drawing.Point(192, 52)
    $btnOpen.Size = New-Object System.Drawing.Size(150, 32)
    $btnOpen.Text = "Open Graph (HTML)"
    $btnOpen.Enabled = $false
    $form.Controls.Add($btnOpen)

    $output = New-Object System.Windows.Forms.RichTextBox
    $output.Location = New-Object System.Drawing.Point(12, 96)
    $output.Size = New-Object System.Drawing.Size(740, 420)
    $output.Font = New-Object System.Drawing.Font("Consolas", 9)
    $output.ReadOnly = $true
    $output.Anchor = "Top,Bottom,Left,Right"
    $form.Controls.Add($output)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 524)
    $status.Size = New-Object System.Drawing.Size(740, 20)
    $status.Anchor = "Bottom,Left,Right"
    $status.Text = "Ready."
    $form.Controls.Add($status)

    $script:LineageHtmlPath = $null

    if (-not $Inventory) {
        $output.AppendText("No API inventory available.`r`n`r`n" +
            "Run 'API Scan' -> 'Run Tenant Scan' first. The lineage graph is built " +
            "from the Scanner API inventory (workspaces, datasets, reports and " +
            "their data sources).")
        $btnBuild.Enabled = $false
    }

    $btnBuild.Add_Click({
        $output.Clear()
        $btnBuild.Enabled = $false
        $status.Text = "Building graph..."
        try {
            $graph = Build-LineageGraph -Inventory $Inventory -LocalScan $LocalScan
            $stats = Get-LineageStats -Graph $graph

            $root = $GovernanceRoot
            if ([string]::IsNullOrEmpty($root)) {
                $fb = New-Object System.Windows.Forms.FolderBrowserDialog
                if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $root = $fb.SelectedPath }
            }
            if ([string]::IsNullOrEmpty($root)) { $root = [Environment]::GetFolderPath("MyDocuments") }

            $script:LineageHtmlPath = Export-LineageGraph -Graph $graph -Stats $stats -GovernanceRoot $root

            $output.AppendText("LINEAGE GRAPH`r`n")
            $output.AppendText(("=" * 74) + "`r`n")
            $output.AppendText(("Nodes: {0}   Links: {1}`r`n" -f $stats.NodeCount, $stats.LinkCount))
            foreach ($t in $stats.TypeCounts) {
                $output.AppendText(("   {0,-12} {1}`r`n" -f $t.Type, $t.Count))
            }
            $output.AppendText("`r`nGOD NODES (widest blast radius)`r`n")
            foreach ($g in $stats.GodNodes) {
                $output.AppendText(("   {0,3}  {1}  [{2}]`r`n" -f $g.Degree, $g.Label, $g.Type))
            }
            $output.AppendText(("`r`nSHARED SOURCES ({0})`r`n" -f @($stats.SharedSources).Count))
            foreach ($s in $stats.SharedSources) {
                $output.AppendText(("   {0}  -> {1} models / {2} workspace(s)`r`n" -f `
                    $s.Source, $s.DatasetsFed, $s.WorkspaceSpan))
            }
            $output.AppendText(("`r`nCROSS-WORKSPACE SOURCES ({0}) - highest governance risk`r`n" -f `
                @($stats.CrossWorkspaceSources).Count))
            foreach ($s in $stats.CrossWorkspaceSources) {
                $output.AppendText(("   {0}  ({1} workspaces)`r`n" -f $s.Source, $s.WorkspaceSpan))
            }
            $output.AppendText(("`r`nORPHAN DATASETS ({0}) - no source visible to the scan`r`n" -f `
                $stats.OrphanDatasets.Count))
            foreach ($o in $stats.OrphanDatasets) {
                $output.AppendText(("   {0} ({1})`r`n" -f $o.Dataset, $o.Workspace))
            }
            $output.AppendText("`r`nFiles written to Analysis_Output\Lineage\ : graph.json, lineage.html, LINEAGE_REPORT.md`r`n")

            $btnOpen.Enabled = $true
            $status.Text = "Graph built. Click 'Open Graph (HTML)' for the interactive view."
        }
        catch {
            $output.AppendText("`r`nERROR: $($_.Exception.Message)`r`n")
            $status.Text = "Failed."
        }
        finally {
            $btnBuild.Enabled = $true
        }
    })

    $btnOpen.Add_Click({
        if ($script:LineageHtmlPath -and (Test-Path $script:LineageHtmlPath)) {
            Start-Process $script:LineageHtmlPath
        }
    })

    [void]$form.ShowDialog()
}

#endregion

# Functions are automatically available when dot-sourced.
