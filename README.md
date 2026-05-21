# PBIP Toolkit — Power BI Governance Manager

A modular PowerShell toolkit for governing Power BI semantic models at scale. It
scans an organized `Governance/WS` folder tree of `.pbix` files, extracts each
model into the source-controllable **PBIP / TMDL** format with
[pbi-tools](https://github.com/pbi-tools/pbi-tools), and surfaces inventory,
storage and structural insight through an interactive Windows GUI.

As of v1.1 the toolkit also talks to the **Power BI REST API** — the Admin
*Scanner API* — to inventory the live tenant and reconcile it against the local
folder structure, so you can see governance drift at a glance.

## What it does

- **Folder scan** — walks `Governance/WS/<Workspace>/<Model>/model.pbix`, reads
  workspace and dataset IDs straight out of each `.pbix` (a ZIP archive, via its
  `Connections` entry), and groups results by workspace.
- **PBIP extraction** — generates / refreshes / deletes `pbip_<model>` source
  folders in bulk, dropping the `Data` cache to keep them small.
- **Interactive statistics** — models, workspace coverage, storage and an
  expand/collapse workspace breakdown, with clickable links into the Power BI
  service.
- **Metadata analysis** — Step 1–4 analyzers parse the extracted TMDL for
  tables, roles (RLS) and expressions.
- **API Scanner** — runs the Power BI Admin Scanner API across the whole
  tenant, builds a workspace / dataset / report / dataflow inventory, and
  produces a **drift report**: models that live in the tenant but are missing
  from the Governance folder, and local files whose dataset no longer exists.
- **Ownership & endorsement** — the drift report enriches the governed models
  with owner and endorsement (Certified / Promoted) from the live service, and
  flags models that are unowned or not certified.
- **Refresh health** — pulls recent refresh history for the governed models
  (last status, duration, failure count) so refresh failures surface alongside
  the inventory.
- **Scan history & drift over time** — saves folder-scan snapshots and diffs
  any two of them (or a snapshot vs. the current scan): models added, removed,
  resized, and PBIP-coverage changes.
- **Lineage graph** — turns the tenant inventory into one interactive,
  self-contained HTML graph (sources, datasets, reports and workspaces),
  interconnected by shared sources and workspaces, plus `graph.json` and a
  markdown report highlighting god nodes and cross-workspace sources. A
  table-level "v2" approach is designed in `docs/LINEAGE-V2-DESIGN.md`.
- **Best-practice analyzer** — parses the extracted TMDL and runs a customizable
  rule set over tables, columns, measures and roles (missing descriptions,
  unformatted measures, empty RLS roles, key columns left summarized, auto
  date/time tables, and more), with severity grouping and CSV / markdown export.
- **Usage & adoption** — pulls Power BI activity events (the Admin API audit
  log), aggregates views, distinct users and last-access per report and dataset,
  and — cross-referenced with the inventory — lists artifacts with no usage at
  all as retirement candidates.
- **Workspace access audit** — pulls every workspace's role assignments
  (`admin/groups` with users) and flags governance risks: workspaces with no
  admin, a single admin (bus factor), external/guest users, very wide sharing,
  and access granted indirectly through security groups.
- **API operations** (separate window) — *bulk workspace access*: add a service
  principal (or user / group) to every workspace in one pass, so the
  per-workspace APIs reach the whole estate; and *TMDL download*: pull a model's
  TMDL definition straight from the Fabric `getDefinition` API — no `.pbix`, no
  pbi-tools and no Power BI Desktop.
- **Headless / CI runner** — `PBIP-Toolkit-CLI.ps1` runs scan, extraction, API
  scan, usage, best-practice, snapshot and lineage with no GUI, with exit codes
  and `-FailOnHighFindings` / `-FailOnDrift` quality gates for Task Scheduler,
  Azure DevOps or GitHub Actions.

## Repository layout

```
PBIP-Toolkit-Main.ps1      Launcher — loads modules, opens the GUI
PBIP-Toolkit-CLI.ps1       Headless / CI runner — no GUI, exit codes
Modules/
  Common.ps1               Dialogs, folder picker, progress window, pbi-tools probe
  Manager-Core.ps1         Folder scan, PBIP generate / delete
  Manager-GUI.ps1          Main window (grouped display, service links)
  Manager-Stats.ps1        Interactive statistics window
  API-Scanner.ps1          Power BI REST / Scanner API: inventory, drift,
                           ownership/endorsement, refresh health
  Usage-Analytics.ps1      Activity events: views, adoption, unused artifacts
  Access-Audit.ps1         Workspace access audit (admins, external users)
  API-Operations.ps1       Bulk workspace access grant + API TMDL download
  Scan-History.ps1         Scan snapshots + drift-over-time comparison
  Lineage-Graph.ps1        Estate lineage graph: graph.json + interactive HTML
  BestPractice-Analyzer.ps1  TMDL best-practice rule engine
  Analyzer-Menu.ps1        Analysis sub-menu (Step 1-4 + Best Practice)
  Step1-Model.ps1          model.tmdl analyzer
  Step2-Tables.ps1         tables analyzer
  Step3-Roles.ps1          roles / RLS analyzer
  Step4-Expressions.ps1    expressions analyzer
scripts/
  Install-PbiTools.ps1     One-time pbi-tools downloader
samples/Governance/        Anonymized example folder structure
docs/                      Strategy, status and feature notes
```

## Getting started

1. **Clone** the repository.
2. **Install pbi-tools** (kept separate for licensing — see below):

   ```powershell
   .\scripts\Install-PbiTools.ps1
   ```

3. **Arrange your models** under a `Governance/WS` tree — see
   [`samples/Governance`](samples/Governance) for the expected layout.
4. **Run the toolkit**:

   ```powershell
   .\PBIP-Toolkit-Main.ps1
   ```

5. Pick the Governance folder, click **Scan Folders**, then use **Generate**,
   **Show Statistics** or **API Scan** as needed.

### Using the API Scanner

The **API Scan** button opens a window that calls the Power BI Admin Scanner
API. You can authenticate two ways:

- **Service principal (unattended)** — supply Tenant ID, Client ID and Client
  Secret. The Entra ID app needs `Tenant.Read.All` and the Power BI tenant
  setting *"Allow service principals to use read-only admin APIs"* enabled.
- **Interactive** — leave the three fields blank to sign in as a Power BI admin.
  Requires the `MicrosoftPowerBIMgmt` module:
  `Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser`.

Results can be exported to JSON and CSV under `Analysis_Output/`.

### Headless / CI runs

`PBIP-Toolkit-CLI.ps1` runs the same operations without a GUI — for Task
Scheduler, Azure DevOps or GitHub Actions. It writes exports under
`Analysis_Output/` and sets an exit code (`0` ok, `1` error, `2` quality-gate
failure).

```powershell
# folder scan + best-practice gate
.\PBIP-Toolkit-CLI.ps1 -GovernanceRoot C:\Governance -Task scan,bestpractice -FailOnHighFindings

# full governance run (admin-API tasks need a service principal)
.\PBIP-Toolkit-CLI.ps1 -GovernanceRoot C:\Governance -Task all `
    -TenantId $env:PBI_TENANT -ClientId $env:PBI_CLIENT -ClientSecret $env:PBI_SECRET
```

Tasks: `scan`, `generate`, `apiscan`, `usage`, `access`, `bestpractice`,
`snapshot`, `lineage`, `all`. Admin-API tasks are skipped (never prompt) when no
service principal is supplied.

## Requirements

- Windows + PowerShell 5.1 (uses `System.Windows.Forms`)
- Power BI Desktop installed (required by pbi-tools Desktop edition)
- For the API Scanner: a Power BI admin account or a suitably permissioned
  service principal

## Licensing note

This toolkit is MIT licensed. **pbi-tools is a separate project under AGPL-3.0**
and is intentionally *not* bundled here; `Install-PbiTools.ps1` downloads it on
demand so this repository can remain permissively licensed. See
[`LICENSE`](LICENSE).

## Roadmap

See [`docs/IMPROVEMENT-STRATEGY.md`](docs/IMPROVEMENT-STRATEGY.md) for the
competitive analysis and the planned evolution of the toolkit.
