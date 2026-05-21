# PBIP Toolkit — Competitive Analysis & Improvement Strategy

_Last updated: 2026-05-20_

## 1. Executive summary

The PBIP Toolkit is a free, local-first PowerShell utility that extracts Power BI
`.pbix` files into source-controllable PBIP/TMDL format and reports on a
governed folder structure. It occupies a real and underserved niche: the
commercial data-governance platforms (Collibra, Microsoft Purview, Atlan,
Alation, Informatica, Dawiso) are catalog-and-lineage products priced for
enterprises and built around live metadata harvesting — none of them give an
individual developer or a small BI team a cheap, offline, file-level grip on
their `.pbix` estate.

The toolkit's weakness is equally clear: it is **blind to the live tenant**.
Today it only sees files on disk. It cannot tell you what exists in the Power BI
service, who owns it, when it last refreshed, or whether a model on disk still
matches reality. Every competitor's core strength is exactly that live view.

This strategy keeps the toolkit in its niche rather than trying to become a
Collibra clone, and closes the live-tenant gap by **leaning hard on the Power BI
REST API**. The new `API-Scanner.ps1` module (shipped in v1.1) is the first step.
The rest of this document lays out the competitive reasoning and a phased
roadmap.

## 2. Where the toolkit stands today

**Strengths**

- Zero cost, zero deployment, no server, no licensing — runs from a folder.
- File-level reach the SaaS platforms do not have: it opens the `.pbix` ZIP
  directly and extracts full TMDL source.
- Source-control orientation: PBIP/TMDL output is diff-friendly and Git-ready.
- A working, responsive GUI with workspace grouping, statistics and drill-down.
- Tight Power BI focus — no generic-catalog abstraction tax.

**Gaps**

- No connection to the live tenant — the single biggest limitation.
- No lineage (upstream data sources → dataset → report → dashboard).
- No ownership, refresh-history, capacity or usage data.
- No automated quality/best-practice rules over the extracted models.
- Step 1–4 analyzers still reference the old folder structure (`ServiceId`,
  `ModelId`) and need updating.
- Manual, GUI-only operation; no headless/CI mode.
- Windows-only (WinForms + pbi-tools Desktop edition).

## 3. Competitive landscape

The market splits into two groups: full enterprise governance platforms, and
Power BI-native tooling. The toolkit competes with neither head-on — but both
define what "good" looks like and where the toolkit can be distinctive.

### 3.1 Enterprise data-governance platforms

**Collibra** — A legacy enterprise governance platform: catalog, policy
enforcement, glossary, 100+ native integrations, and 30+ out-of-the-box lineage
scanners including a dedicated Power BI lineage harvester (attribute-level
lineage, dataflow ingestion). It is powerful but heavy: a Collibra Data
Intelligence Cloud subscription is reported around **$170,000/year**, with
governance, lineage and data-quality licensed and priced separately, so true
total cost is higher. Deployment is a project, not an afternoon.

**Microsoft Purview** — The most direct strategic reference point, because it is
Microsoft's own answer to Power BI governance. Purview's Data Map registers and
scans Power BI workspaces, reports and datasets, and automatically captures
end-to-end lineage (dataflow → dataset → report → dashboard) plus upstream
sources. It adds classification, sensitivity labels, DLP, data products and data
quality scoring, and the 2026 Purview–Fabric integration deepens this further.
Purview is the platform the toolkit should interoperate with, not fight.

**Atlan** — A modern "active metadata" platform: automated column-level lineage
across 200+ connectors (including Power BI), tag propagation along lineage paths,
DIY setup in days-to-weeks. Frequently cited as the leading alternative to the
legacy vendors.

**Alation** — A traditional catalog focused on search, stewardship and BI
documentation. Notably, column-level lineage for key sources is a separately
licensed parser add-on; standard licensing stops at table level. Deployment
typically takes 3–9 months with professional services.

**Informatica** — Enterprise data-management suite with cataloging and lineage;
broad but heavyweight, and increasingly compared unfavourably on time-to-value
against Atlan-style platforms.

**Dawiso** — The most relevant "modern, lighter" competitor and worth close
attention. Dawiso is a data catalog / "AI context layer" that connects to Power
BI, Snowflake, Azure Data Factory, WhereScape and SQL. It builds context through
**automated scanning plus AI enrichment** rather than manual data entry, offers a
business glossary, and — notably — **Power BI visual-level lineage**: tracing the
data behind an individual card or chart back to a governed model definition.
Dawiso also exposes governance checks through the Model Context Protocol (MCP) so
CI/CD pipelines can verify that datasets have documented definitions, an owner,
and glossary-consistent column names before promotion. Dawiso shows where a
lighter, automation-first, AI-assisted product is heading.

### 3.2 Power BI-native tooling (the toolkit's real neighbourhood)

Tabular Editor, Best Practice Analyzer, Measure Killer, DAX Studio, ALM Toolkit,
and pbi-tools itself. These are developer tools, mostly free or low-cost,
file/model-centric — the same space the PBIP Toolkit lives in. The opportunity is
to be the **orchestrator and governance layer** that ties folder structure, PBIP
extraction, the REST API and best-practice analysis together, which none of these
single-purpose tools do.

### 3.3 Capability comparison

| Capability | PBIP Toolkit (today) | Dawiso | Collibra | Purview | Atlan/Alation |
|---|---|---|---|---|---|
| Cost | Free | $$ | $$$$ | $$ (Azure) | $$$ |
| Deployment effort | Minutes | Low | High (project) | Medium | Low–Medium |
| `.pbix` file-level source extraction | **Yes** | No | No | No | No |
| Source-control / TMDL diff workflow | **Yes** | Partial | No | No | No |
| Live tenant inventory | No → **v1.1** | Yes | Yes | Yes | Yes |
| End-to-end lineage | No | Yes (visual-level) | Yes | Yes | Yes (column-level) |
| Ownership / refresh / usage | No | Partial | Yes | Yes | Yes |
| Best-practice / quality rules | No | Yes | Yes (add-on) | Yes | Partial |
| Offline operation | **Yes** | No | No | No | No |
| Power BI-specific focus | **Yes** | Partial | No | Partial | No |

## 4. Strategic positioning

The toolkit should **not** chase Collibra or Purview on catalog breadth, AI
enrichment or enterprise workflow. It wins by being the thing none of them are:
a free, offline-capable, source-control-native, Power BI-specific governance
utility that a developer or small BI team can run today.

The sharpened positioning: **"Git-grade governance for your Power BI estate —
extract every model to source, scan the live tenant, and see the drift between
them, with no platform and no licence."**

Three principles follow:

1. **Close the live-tenant gap with the REST API** — the API is free, official,
   and removes the toolkit's single biggest weakness without adding cost.
2. **Pair file truth with service truth** — the toolkit's unique value is being
   the *only* tool that holds both the extracted source and the live inventory,
   so it can report drift between them. This becomes the headline feature.
3. **Stay interoperable, not isolated** — export to formats Purview and Git
   consume rather than trying to replace them.

## 5. Power BI REST API — the maximum-tools plan

The toolkit should use the Power BI REST API to the fullest. The endpoints
below, grouped by what they unlock, form the backbone of the roadmap.

### 5.1 Admin Scanner API (metadata scanning) — shipped in v1.1

The asynchronous Scanner API is the richest source of tenant metadata and needs
only `Tenant.Read.All` (no workspace membership):

- `GET admin/workspaces/modified` — list workspaces (supports `modifiedSince`
  for incremental scans).
- `POST admin/workspaces/getInfo` — queue a scan; request the full payload with
  `lineage=true`, `datasourceDetails=true`, `datasetSchema=true`,
  `datasetExpressions=true`, `getArtifactUsers=true`. Batches of up to 100
  workspaces.
- `GET admin/workspaces/scanStatus/{scanId}` — poll until `Succeeded`.
- `GET admin/workspaces/scanResult/{scanId}` — download workspaces, datasets
  (tables, columns, measures, DAX, M queries), reports, dashboards, dataflows,
  data sources, sensitivity labels and endorsement status.

`API-Scanner.ps1` already implements this workflow, flattens the result into a
workspace/dataset/report/dataflow inventory, and reconciles it against the local
folder scan to produce a drift report.

### 5.2 Admin & group APIs — ownership and structure (Phase 2)

- `GET admin/groups` — workspace list with state, capacity, type.
- `GET admin/groups/{id}/users` — workspace role assignments (ownership).
- `GET admin/datasets` / `admin/reports` — tenant-wide artifact lists.
- `GET admin/capacities` — capacity / Premium / Fabric assignment.

### 5.3 Refresh, health and usage (Phase 3)

- `GET datasets/{id}/refreshes` — refresh history, durations, failures.
- `GET groups/{id}/datasets/{id}/refreshSchedule` — configured schedules.
- `GET admin/activityevents` — audit/usage activity for adoption metrics.

### 5.4 Lineage (Phase 3)

- `GET admin/groups/{id}/datasources` and the Scanner API's
  `datasourceInstances` / `upstreamDatasets` — to build source → dataset →
  report lineage and approach what Dawiso and Purview offer.

### 5.5 Authentication

Two paths, both already in `API-Scanner.ps1`:

- **Service principal** — Entra ID app registration + client secret/certificate,
  the Power BI tenant setting *"Allow service principals to use read-only admin
  APIs"* enabled. The right choice for unattended/CI use. Secrets belong in
  Azure Key Vault and should be rotated (~90 days), never committed.
- **Interactive admin** — via the `MicrosoftPowerBIMgmt` module for ad-hoc runs.

## 6. Phased roadmap

### Phase 1 — Close the live-tenant gap _(v1.1 — done)_

- `API-Scanner.ps1`: Scanner API workflow, tenant inventory, drift report.
- GUI **API Scan** button; JSON/CSV export of the inventory.
- Service-principal and interactive authentication.

### Phase 2 — Reconciliation & hygiene _(v1.2 — done)_

- ✅ Step 1–4 analyzers aligned to the current folder structure (the
  `ServiceId`/`ModelId` references were already migrated; field naming
  standardised on `ModelName` and stale messages removed).
- ✅ Scan history persisted as JSON snapshots (`Scan-History.ps1`), with a
  drift-over-time comparison window.
- ✅ Ownership and endorsement enrichment pulled from the API into the drift
  report (unowned and uncertified models flagged).
- Flag stale models: on disk but unrefreshed for N days, or orphaned in the
  tenant. _(partially covered — refresh health, below, surfaces this.)_
- Detect live-connected reports vs. semantic models. _(still open.)_

### Phase 3 — Insight & lineage _(v1.3 — done)_

- ✅ Refresh-health view: last status, duration, failure count per governed
  model (`Get-RefreshHealthReport` + the API Scanner window).
- ✅ Estate-wide lineage graph (`Lineage-Graph.ps1`): source → dataset → report
  as one interactive, self-contained HTML graph, plus `graph.json` and a
  graphify-style markdown report. Shared sources and workspaces interconnect the
  whole estate; god nodes and cross-workspace sources are surfaced.
- ✅ Usage/adoption metrics from `admin/activityevents` (`Usage-Analytics.ps1`):
  views, distinct users and last-access per report and dataset, plus unused
  artifacts cross-referenced against the inventory.
- ✅ Best-practice analyzer over extracted TMDL (`BestPractice-Analyzer.ps1`):
  a customizable rule engine over tables, columns, measures and roles, run from
  the Analyzer menu, with severity grouping and CSV/markdown export.

### Phase 3.5 — Lineage v2: bipartite, table-level _(next)_

Designed in [`LINEAGE-V2-DESIGN.md`](LINEAGE-V2-DESIGN.md). A second graph
"approach": sources and models as two community-structured halves
(databases/schemas vs. workspaces), bridged by **table-level** lineage extracted
from TMDL/M, with pluggable source resolvers, a persisted source index,
workspace/report filtering, and an AI-reusable markdown context file. The graph
approach itself becomes pluggable so further approaches can be added.

### Phase 4 — Automation & interoperability _(v2.0)_

- ✅ Headless mode (`PBIP-Toolkit-CLI.ps1`): scan / extract / API scan / usage /
  best-practice / snapshot / lineage with no GUI, exit codes and
  `-FailOnHighFindings` / `-FailOnDrift` quality gates for scheduled jobs and
  CI/CD pipelines.
- ✅ HTML/Markdown governance report export for sharing (across the lineage,
  best-practice, usage and API-scan exporters).
- Optional cross-platform path: PowerShell 7 + pbi-tools Core to lift the
  Windows-only constraint.

## 7. Prioritized backlog

| Priority | Item | Why | Status |
|---|---|---|---|
| P0 | Scanner API integration + drift report | Removes the toolkit's biggest weakness | ✅ Done (v1.1) |
| P0 | Fix Step 1–4 analyzers for current structure | Blocked analysis features | ✅ Done (v1.2) |
| P1 | Ownership & endorsement enrichment | Cheap API win; high governance value | ✅ Done (v1.2) |
| P1 | Scan history / drift over time | Turns a snapshot into a trend | ✅ Done (v1.2) |
| P1 | Refresh-history view | Most-requested operational signal | ✅ Done (v1.3) |
| P2 | Lineage graph (source → dataset → report) | Closes the gap with Dawiso/Purview | ✅ Done (v1.3) |
| P2 | Lineage v2 — bipartite, table-level (see LINEAGE-V2-DESIGN.md) | Table-grain lineage + extraction + AI context | Designed; next |
| P2 | Best-practice analyzer over TMDL | Differentiates vs. single-purpose tools | ✅ Done (v1.4) |
| P2 | Headless / CI mode | Enables automation and scheduling | ✅ Done (v1.4) |
| P2 | Usage / adoption metrics (activity events) | Finds unused artifacts | ✅ Done (v1.4) |
| P2 | Workspace access audit (admin/groups users) | Workspace-level security governance | ✅ Done (v1.5) |
| P2 | Bulk workspace access grant + API TMDL download | SP access at scale; TMDL with no pbi-tools | ✅ Done (v1.5) |
| P3 | PowerShell 7 / cross-platform | Widens the addressable user base | Open |

## 8. Risks & constraints

- **Admin API access** — the Scanner and admin endpoints need a Power BI admin
  or a tenant-approved service principal. Some users will not have this; the
  toolkit must degrade gracefully to folder-only mode (it does).
- **Throttling** — admin APIs are rate-limited; `API-Scanner.ps1` already
  handles HTTP 429 with `Retry-After` back-off. Incremental `modifiedSince`
  scans keep volume down.
- **Secret handling** — service-principal secrets must never be committed.
  `.gitignore` excludes `*.secret`, `*.env` and credential files; documentation
  points users to Azure Key Vault.
- **pbi-tools licensing** — pbi-tools is AGPL-3.0 and is *not* bundled;
  `Install-PbiTools.ps1` fetches it so this repository stays MIT-licensed.
- **Scope discipline** — the toolkit's advantage is being small and free.
  Resist feature creep toward a full catalog; every addition should reinforce
  the file-truth + service-truth positioning.

## 9. Sources

- Dawiso — https://www.dawiso.com/ ; visual-level lineage —
  https://www.dawiso.com/blog-post/power-bi-visual-level-lineage-trace-data-to-every-table-or-chart ;
  pricing/features — https://www.softwaresuggest.com/dawiso
- Collibra — https://www.collibra.com/products/collibra-platform ; Power BI
  lineage — https://marketplace.collibra.com/listings/power-bi-service/ ;
  pricing — https://atlan.com/collibra/pricing/
- Microsoft Purview — https://learn.microsoft.com/en-us/purview/unified-catalog ;
  Power BI governance —
  https://powerbiconsulting.com/blog/microsoft-purview-power-bi-data-lineage-governance
- Atlan / Alation — https://atlan.com/alation-vs-collibra-vs-informatica-vs-atlan/ ;
  https://atlan.com/alation-alternatives/
- Power BI Scanner API —
  https://learn.microsoft.com/en-us/rest/api/power-bi/admin/workspace-info-get-scan-result ;
  https://learn.microsoft.com/en-us/power-bi/enterprise/service-admin-metadata-scanning
- Power BI REST API automation —
  https://powerbiconsulting.com/blog/power-bi-rest-api-automation-guide-enterprise-2026
- Service principal auth —
  https://learn.microsoft.com/en-us/powershell/module/microsoftpowerbimgmt.profile/connect-powerbiserviceaccount
- pbi-tools — https://github.com/pbi-tools/pbi-tools
