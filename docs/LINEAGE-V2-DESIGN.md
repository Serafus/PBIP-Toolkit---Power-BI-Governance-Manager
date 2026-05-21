# Lineage v2 — Design: Bipartite Community Graph with Table-Level Extraction

_Status: design / not yet implemented. Target: the iteration after v1.3._

## 1. Where we are and what v2 changes

Lineage v1 (shipped in v1.3, `Modules/Lineage-Graph.ps1`) builds **one
interconnected graph of the whole estate** from the Power BI Scanner API:
workspaces, datasets, reports and data sources as nodes, with shared sources and
shared workspaces as the connective tissue. It answers "what connects to what at
the artifact level" and surfaces god nodes and cross-workspace sources.

v1 has two real limits. First, it is **source-level, not table-level** — it
knows model X uses "Azure SQL: salesdb", but not that the model's `FactSales`
table is built from `dbo.FactSales` filtered to the last two years. Second, it
is **one flat graph** — at a few hundred artifacts that is fine; at a few
thousand tables it becomes an unreadable hairball.

v2 addresses both. It adopts the graphify principle — turn the corpus into a
navigable, queryable graph with a portable report — but reshapes it for Power BI
governance specifically: a **bipartite, community-structured graph** with
**table-level lineage extracted from the model definitions**, and a **markdown
context file** an AI assistant (or a human) can consume directly.

This document is the design. It is deliberately ahead of the code so the
approach can be reviewed before implementation.

## 2. Principle: graph "approaches" are pluggable

v1 and v2 are not a replacement pair — they are two **approaches** to the same
estate, each better for a different question. v1 ("Estate Overview") is the
right altitude for "which sources are load-bearing across the org." v2
("Bipartite Table Lineage") is the right altitude for "if this source table
changes, which model tables and reports break."

So the toolkit should not hard-code one graph shape. It gets a small abstraction
— a **graph approach** — selected by the user, with v1 and v2 as the first two
implementations and room for more (a column-level approach, a
refresh-dependency approach, a security/RLS approach later).

```
GraphApproach (contract)
  Name        : "EstateOverview" | "BipartiteTableLineage" | ...
  Build(context) -> Graph     # context = API inventory + local extraction + options
  Describe()  -> short text shown in the picker
```

`Show-LineageWindow` gains an approach dropdown; `Build-LineageGraph` becomes a
dispatcher that delegates to the selected approach. This is the user's "should
be customizable on approaches" requirement made concrete: a new approach is a
new module that satisfies the contract, registered like a resolver (section 6),
with no change to the GUI or exporters.

## 3. The bipartite community model

v2 splits the graph into two **halves** that face each other, joined by a thin
**bridge layer**. The thesis behind the split: sources and models are governed
by different people, change for different reasons, and scale independently —
forcing them into one undifferentiated graph hides that structure. Keeping them
as two halves with an explicit bridge makes the *interface* between them — which
is exactly where governance risk lives — the visible thing.

### 3.1 The source half

The source half is a hierarchy, and the hierarchy levels *are* the communities:

```
DataSource (server / endpoint)        community, level 0
  └─ Database                         community, level 1
       └─ Schema                      community, level 2
            └─ Table                  leaf node, level 3
                 └─ Column            leaf node, level 4   (optional, see §7)
```

A community is not computed by a clustering algorithm — it is the database and
schema the table genuinely belongs to. That is deliberate: deterministic,
O(n) grouping that is correct by construction and stable between scans. Two
model tables that both read `salesdb.dbo.FactSales` resolve to the *same* leaf
node, so every model drawing on that table is visibly tied to it — the
cross-governance interconnection the brief asks for, now at table grain.

### 3.2 The model half

The model half mirrors it:

```
Workspace                             community, level 0
  └─ Semantic model (dataset)         community, level 1
       └─ Model table                 leaf node, level 2
            └─ Model column            leaf node, level 3   (optional)
```

Workspace is the community, as the brief specifies. The semantic model is a
sub-community; the model table is the leaf that participates in lineage.

A note on a design fork the brief leaves open: "models and workspaces as
communities" could mean the *model* is the leaf node. v2 instead makes the
**model table** the leaf, because table-level lineage is the whole point of v2 —
you cannot bridge to source tables from a model node that has no tables. The
model remains as a community so the "model as a unit" view is preserved by
collapsing it. Both readings are satisfied: collapse a model to see it as one
node, expand it to see its tables.

### 3.3 The bridge layer

Between the two halves sits one edge type that carries the governance signal:

```
ModelTable  ──lineage──▶  SourceTable
   payload: { resolver, transformations[], confidence }
```

A model table can bridge to several source tables (a join), and a source table
can bridge to many model tables (reuse). These bridge edges are the only edges
that cross the halves; everything else is intra-half structure. That keeps the
picture legible: the bridge layer, viewed alone, *is* the lineage.

Report nodes hang off the model half (report → model, via `report.datasetId`)
so a report can be traced report → model → model tables → bridge → source
tables in one path.

## 4. Source extraction — the core new capability

v1 relies on the Scanner API's `datasourceInstances`, which stop at the source
*instance*. v2 needs table grain, and that information only exists in the model
definition itself. So v2 **extracts** lineage from the TMDL/M that `pbi-tools`
already produces under each `pbip_<model>/Model/tables/*.tmdl`.

Each model table's TMDL contains a `partition` with an M (Power Query)
expression. A representative one:

```m
let
    Source       = Sql.Database("sql-prod.company.net", "SalesDB"),
    dbo_FactSales = Source{[Schema="dbo", Item="FactSales"]}[Data],
    Filtered     = Table.SelectRows(dbo_FactSales, each [OrderYear] >= 2023),
    Trimmed      = Table.RemoveColumns(Filtered, {"InternalGuid"})
in
    Trimmed
```

The extraction engine reads this and produces a **lineage fact**:

```
{
  modelTable      : "FactSales",
  model           : "Sales Model",
  workspace       : "Sales",
  source          : { type:"Sql", server:"sql-prod.company.net",
                       database:"SalesDB", schema:"dbo", table:"FactSales" },
  transformations : [ "SelectRows: OrderYear >= 2023",
                       "RemoveColumns: InternalGuid" ],
  confidence      : "EXTRACTED"
}
```

The `confidence` tag is borrowed straight from graphify: `EXTRACTED` when the
source table was parsed unambiguously, `INFERRED` when it was reconstructed from
a partial expression, `AMBIGUOUS` when a dynamic expression (a parameter, a
function call, generated M) made the source uncertain. Governance users must
know what was read versus guessed.

Extraction runs over the local `pbip_*` folders, so it works **offline** and
needs no admin API — a deliberate strength. The Scanner API stays in the loop as
*enrichment and fallback*: it confirms the source instance, supplies gateway and
endorsement, and covers models that have not been extracted locally.

## 5. The bridge join, indexed

Once every model table has a lineage fact, building the bridge is a hash join.
Each source reference is reduced to a **normalized source-table key**:

```
key = lower( type | server | database | schema | table )
```

All keys go into a **source index** (section 8). A model table links to a source
table by key lookup — O(1) per table, O(n) overall. The same key produced by two
different models collapses to one source-table node automatically. No
pairwise comparison, no clustering pass; the join is the index.

## 6. Pluggable source resolvers

Power Query has dozens of connectors and the navigation idiom differs per
connector (`Sql.Database(...){[Schema=,Item=]}` vs `Snowflake.Databases(...)` vs
`Excel.Workbook(File.Contents(...))` vs SharePoint vs a custom connector). New
connectors appear constantly. The brief is explicit: source identification must
be **customizable**, because new source types and new identification algorithms
will be needed. So extraction is not one big switch statement — it is a
**registry of resolvers**.

```
SourceResolver (contract)
  Name        : "AzureSqlResolver"
  Priority    : int   # lower runs first; first confident match wins
  Match(m)    : bool                      # is this my connector?
  Extract(m)  : LineageFact[]             # pull source tables + transforms
  CanIndex    : bool                      # can it introspect the live source? (§7)
  IndexSchema(connection) : SourceTable[] # optional deep introspection
```

Resolvers live in `Modules/Resolvers/*.ps1` and self-register via
`Register-SourceResolver`. The extraction engine, for each M expression, walks
resolvers by priority and takes the first confident match (or merges matches for
multi-source expressions). Shipping set: SQL Server, Azure SQL, Synapse,
Snowflake, Databricks, Fabric Lakehouse/Warehouse, Analysis Services, Excel,
CSV/Folder, SharePoint, OData, Web, and Dataflow/Datamart references.

For the long tail, a **GenericRegexResolver** is driven by a config file rather
than code, so a new source type can be added without PowerShell at all:

```jsonc
// config/source-resolvers.json
[
  { "name": "MyWarehouse", "priority": 50,
    "matchRegex": "MyWarehouse\\.Contents",
    "serverGroup": 1, "databaseGroup": 2, "tableGroup": 3,
    "extractRegex": "MyWarehouse\\.Contents\\(\"([^\"]+)\",\"([^\"]+)\"\\).*Item=\"([^\"]+)\"" }
]
```

This two-tier design — code resolvers for real connectors, config resolvers for
quick additions — is what makes "new identification algorithm" a drop-in rather
than a release. An "identification algorithm" can also be a whole resolver that,
say, calls a model API to interpret obfuscated M; the contract does not care how
`Extract` reaches its answer.

## 7. Indexed definitions and "selection against the database"

The brief asks that scanning be able to **extract a definition against the
database** — an indexed catalog of what the source actually contains — and
connect it to the individual model tables and their transformations.

This is the optional deep tier. A resolver whose `CanIndex` is true can, given
connection details and read-only credentials, introspect the live source:

```sql
-- SQL-family example, run read-only by SqlResolver.IndexSchema()
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM   INFORMATION_SCHEMA.COLUMNS;
```

The result is persisted as an **indexed definition** of that source — its real
tables and columns. The bridge join then matches model tables not against a
key *parsed from M* but against a key *verified to exist*. That unlocks the
governance checks v1 cannot do: a model table pointing at a source table that no
longer exists, a transformation referencing a dropped column, a schema drift
between what the model expects and what the database now offers.

Introspection is opt-in per source (it needs credentials and network reach), it
is incremental (re-index on demand, not every scan), and a source with no index
simply falls back to the parsed key — the graph still builds, just with
`INFERRED` confidence on those bridges instead of `EXTRACTED`.

## 8. Persistence: the source and lineage index

Two JSON artifacts under `Analysis_Output\Lineage\` make v2 scalable and
queryable without re-extraction:

`source-index.json` — the catalog of every discovered (and optionally
introspected) source table:

```jsonc
{
  "sql|sql-prod.company.net|salesdb|dbo|factsales": {
    "type":"Sql", "server":"sql-prod.company.net",
    "database":"SalesDB", "schema":"dbo", "table":"FactSales",
    "introspected": true,
    "columns": ["OrderId","OrderYear","Amount","CustomerId"],
    "firstSeen":"2026-05-20", "usedByCount": 7
  }
}
```

`lineage-facts.json` — one record per model table, with a content hash of the
source TMDL so the next scan only re-extracts tables whose definition changed:

```jsonc
{
  "Sales/Sales Model/FactSales": {
    "sourceKeys": ["sql|sql-prod.company.net|salesdb|dbo|factsales"],
    "transformations": ["SelectRows: OrderYear >= 2023", "RemoveColumns: InternalGuid"],
    "confidence": "EXTRACTED",
    "tmdlHash": "9f2c…"
  }
}
```

Incremental extraction (hash, re-extract only changes) plus a persisted index is
what keeps v2 usable on a large tenant — a full re-parse of thousands of TMDL
files every run would not be.

## 9. Filtering by workspace and report

The brief requires the connections and context to be **filterable by
workspace/report**. With the bipartite model this is a focused subgraph, not a
new data structure. The viz and the exporters share one operation:

> Given a focus (a workspace, a model, or a report), return the subgraph of
> everything reachable across the bridge within N hops.

Focus a **report** → its model → that model's tables → bridge → source tables →
(optionally) other model tables on those same source tables. Focus a
**workspace** → all its models and their full source footprint. The result is a
small, legible slice even when the whole estate is large, and the markdown
context file (section 10) can be generated for that slice alone — a per-team
context document.

Implementation is a bounded breadth-first traversal over the precomputed
adjacency; the hop limit and "include sibling models on shared sources" are user
toggles.

## 10. The markdown context file (AI-reusable fallback)

graphify's most reused output is not the graph — it is `GRAPH_REPORT.md`, the
portable distillation. v2 produces `LINEAGE_CONTEXT.md`: the lineage as
structured prose an AI assistant can load as ground truth when the interactive
graph or the live API is not available — the "fallbackable context" the brief
calls for.

Its structure:

```
# Power BI Lineage Context
## Estate summary        — counts, god nodes, cross-workspace sources
## Sources               — per database/schema: tables, and which models consume each
## Models                — per workspace → model → table → source table(s) + transformations
## Risk register         — orphan tables, ambiguous extractions, schema drift, single-points-of-failure
## Suggested questions   — questions this lineage is uniquely positioned to answer
```

It is regenerable per filter (section 9), so a workspace owner can hand their AI
assistant just their slice. Because it is plain markdown with stable headings,
it diffs cleanly in git and can be committed alongside the code — the lineage
becomes reviewable in pull requests.

## 11. Scalability summary

The design is scalable by construction rather than by optimization:

Communities are deterministic (database, schema, workspace) — no clustering pass,
O(n) grouping, stable between runs. The bridge is a hash join over an index —
O(n), no pairwise comparison. Extraction is incremental — content-hashed TMDL,
only changes re-parsed. The index is persisted — the graph and context
regenerate without re-extraction. The viz renders **communities collapsed by
default** — the estate opens as a few dozen database and workspace super-nodes,
and a community expands to its tables only on click, with labels suppressed
below a zoom threshold (level-of-detail). And filtering (section 9) means the
working set is almost always one workspace, not the whole tenant.

The one genuine cost centre is live database introspection (section 7); it is
opt-in, incremental, and parallelizable per source, and never on the critical
path of building the graph.

## 12. Phased implementation plan

The work breaks into phases that each ship something usable:

**Phase A — Extraction engine + resolver registry.** The `SourceResolver`
contract, `Register-SourceResolver`, the shipping code resolvers, the
`GenericRegexResolver` and its config. Output: `lineage-facts.json` from local
`pbip_*` folders. Testable on its own against extracted models.

**Phase B — Bipartite graph builder.** The `BipartiteTableLineage` graph
approach: the two community hierarchies, the indexed bridge join,
`source-index.json`. Plugs into the existing approach dispatcher.

**Phase C — v2 visualisation.** Collapsible community rendering, level-of-detail,
the workspace/report focus filter. Extends the current self-contained HTML.

**Phase D — Markdown context file.** `LINEAGE_CONTEXT.md`, whole-estate and
per-filter, with the risk register.

**Phase E — Live introspection (optional tier).** `CanIndex`/`IndexSchema` on the
SQL-family resolvers, schema-drift detection, credential handling via the
existing secret-safe pattern.

**Phase F — Incrementality.** Content-hash gating so re-scans only re-parse
changed model tables; index reuse.

Phases A–D deliver the full bipartite, table-level, filterable, AI-reusable
lineage offline. E and F are depth and scale on top.

## 13. Stated assumptions and open questions

The design assumes model-table grain is the right leaf for v2 and treats column
grain as an optional later level (sections 3.1, 3.2) — column-level lineage
multiplies node count and is better as its own approach once table-level is
proven. It assumes `pbi-tools` extraction has already run for the models in
scope; models with no local `pbip_` folder appear in the graph from API data
but with no table-level bridge until extracted. It assumes resolver authors can
write PowerShell or the regex config; a fully GUI-driven resolver builder is out
of scope. Open for review: whether dataflows and datamarts should be a third
half or be folded into the source half as just another source type (current
lean: source half — they behave like a source to a model); and whether the MD
context file should be one file or one per workspace by default (current lean:
one whole-estate file plus on-demand per-workspace).
