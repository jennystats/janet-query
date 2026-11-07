# Spec - janet-query public API contract (v1.1)

janet-query is the engine-agnostic compositional query layer (installed
as `jennystats/query`, the name covers the query act only). This
contract states what the layer promises a caller: the node set each
backend serves, the backend contract, the result shape and the error
grammar. The two published engine contracts it executes through are the
authority for engine behaviour; this contract is the authority for the
layer's own surface.

The checked arm of the intersection rule is
`specs/intersection.qnt`; the reference scope machine is
`specs/scope-model.qnt`; the catalogue lanes are
`specs/catalogue-record.qnt`, `specs/catalogue-shapes.qnt` and
`specs/catalogue-partb.qnt`. The empirical arm is the 8.2.2/8.4
equivalence suites.

Run names and invariant names in the Quint specs are stable
identifiers, cited by this contract and by the verification record. They
are not a change log.

## 1. Premise and layering

One compositional query surface - inert Janet data, the node tree -
compiled DOWN to each engine's native execution form. A backend is a
translator, not a dialect.

- janet-query TARGETS the packed-buffer data plane built on
  janet-num; it does not absorb it. The query layer
  consumes datasets and returns results; the substrate stays in the
  data-plane modules.
- Execution goes THROUGH engine modules: the duckdb backend renders
  node trees to SQL text and runs janet-duckdb's existing ffi path
  (contract v1.4); the rayforce backend translates node trees to
  op-plan DAG calls on janet-rayforce's DAG surface (contract v1.0 +
  addenda A1-A12).
- One query, one backend, per execution. Cross-backend queries - a
  single tree spanning engines - are out of scope BY CONSTRUCTION:
  backend selection resolves to exactly one backend or raises
  (section 4.3). Cross-engine pipelines route through Parquet.
- No SQL parsing anywhere in the stack: the tree is the table-name
  source, the renderer emits names, nothing downstream recovers them
  from text. The escape nodes (section 3.4) are the one documented
  exception, and they carry text/handles IN, never out.
- Future stores are new translators of the same node tree - a
  registration property (section 4.1), not an aspiration: the core
  knows only the contract (node set, intersection rule, denial
  shapes), nothing about any specific engine.

## 2. Result shape

`execute` returns exactly one wrapper, for every backend:

```
@{:rows @[...] :columns [...]}
```

- The wrapper is the ONLY result form from `execute`. There is no
  bare-rows return, no per-backend variant - one shape, defined once
  (the result-shape requirement), so the 8.2.2/8.4 equivalence checks can compare
  across backends.
- `:columns` is a vector of column names in projection order;
  `:rows` is a vector of rows, each row a positional TUPLE aligned to
  `:columns` (a row is NOT a struct: Janet struct field order is not
  a language property, so column order is observable ONLY via
  `:columns`). Rows are tuples; the core
  seam normalises any sequence row a backend returns into a tuple, so
  the shape holds by construction rather than by backend convention.
- NULL <-> nil: an engine NULL maps to Janet `nil` in the row payload,
  both directions, per backend contract.
- NaN: the wrapper passes a NaN payload through as the value NaN,
  distinct from `nil` - WHERE THE BACKEND DELIVERS IT AS SUCH. This is
  a documented per-backend asymmetry (stated, not hidden): duckdb keeps NaN distinct from NULL (contract
  v1.4); the rayforce f64 lane has the unified NaN/null mapping
  (rayforce contract A2 - any NaN payload decodes as `nil`, both
  directions, by engine design, unimplementable-around at this seam).
  A NaN-valued column therefore reads NaN-distinct on duckdb and
  nil-unified on rayforce; NaN-bearing lanes are excluded from
  dual-backend equivalence cells until the test plan either accepts
  the documented divergence or normalises it).
- Literal NaN: on the rayforce renderer a NaN LITERAL (in a value, a
  predicate or an expression constant) is normalised to an explicit
  NULL in the carrier form the renderer hands back, because the f64
  lane admits no second meaning for NaN (A2). The rendered form is
  therefore the observable statement of the mapping: a caller holding
  a rayforce form sees `nil`, where the duckdb renderer keeps the NaN
  literal. At execution the normalised literal composes through the
  existing nil-literal boundary rather than reaching the engine.
  The boundary is LANE-DEPENDENT: a NaN literal in a
  value or predicate renders as `:rayforce-nil-literal`; a NaN in an
  aggregate argument or a group key renders as
  `:rayforce-agg-column` / `:rayforce-group-key-column` respectively.
  The named class follows the lane that carried the value, and the
  invariant is the safety property, not the class name: every NaN
  boundary is raised typed, before the engine sees the tree, with the
  offending node named in `:node`.
- Integer exactness: the 2^53 rule inherited per backend contract -
  values outside the double-safe band [-2^53, 2^53] raise the
  backend's typed validation class, never a silent truncation.

**The core seam.** The section 2 wrapper is
produced BY THE CORE, not by backend convention. A backend's execute
returns its raw value; the execute pipeline validates and normalises it
at the seam:

- a dictionary carrying both a sequence `:rows` and a sequence
  `:columns` is the wrapper shape, and is normalised through
  `wrap-result` (row arrays become tuples, column sequences become
  vectors);
- anything else raises `{:error :internal :kind :bad-result-shape}`
  naming the backend. A bare row sequence, a table missing one of the
  keys, or a wrapper nested inside another sequence is not a result.

`wrap-result` therefore carries the ratified 1A row shape in its body
as well as its docstring: every row it returns is a tuple.

## 3. The node set, classified (CLASSIFICATION-GATED - section 9)

Nodes are inert Janet values; composition is `->` threading; every
query is inspectable before execution (`render` shows the plan shape
and, given `:backend`, the rendered form, without executing).

### 3.1 Shared (the intersection, v1)

An operator is in the shared surface only if EVERY backend implements
it with the same semantics (the intersection rule).
Membership requires the 8.2.1 bar: value-equivalence AND documented
identical NULL and error semantics, on both backends, against
hand-computed expected values.

| node | notes |
|---|---|
| from | with optional `:alias` keyword argument for self-joins: `(from :employees :alias :e1)`; column qualification follows the alias. Shared: the rayforce renderer materialises each aliased side with alias-qualified column names, projects explicitly, and never surfaces unprojected rayforce join output (same-named columns collapse into a cross-side mix there; no rename primitive exists on the module) |
| where | per-backend, NOT shared: rayforce's filter is two-valued (nulls compare as negative infinity; a null row is kept by lt/le/ne at any threshold), SQL where is three-valued (unknown drops the row). Duckdb serves native SQL WHERE; rayforce serves filter with the null semantics documented in its matrix |
| join | per-backend, NOT shared: rayforce joins null keys to null keys (SQL never matches null keys), and the module's `:anti` lane through `ray_join` jtype 3 returns left-join output (the engine's real anti, `ray_antijoin`, is unbound). Duckdb serves all variants as a per-backend extension; rayforce serves inner/left/full as a per-backend extension with null-matching keys documented. Promotion to shared rides a named janet-rayforce slice (null-key alignment and a correct anti join) |
| group | aggregate set sum / avg / count / min / max / first / last / stddev / var are v1 shared; count-distinct and median are per-backend - count-distinct is fenced off by the rayforce engine contract (no working structural reducer), median/quantile is absent from the module's agg surface. Duckdb serves both natively as extensions. The remaining aggregates' NULL lanes must be exercised by the build suite's 8.2.1 cells before their matrix rows count as final |
| select | column order follows the projection; `from`-only queries use the source column order as implicit projection. Shared for source-named projections; renamed outputs (AS) are per-backend (rayforce has no rename primitive - an output column is always the source column's name) |
| order | row order becomes significant (section 6) |
| limit | head / tail forms |
| distinct | shared, NaN lanes excluded (the rayforce unified NaN/null mapping; NaN keys diverge by construction - confirmed for distinct, group keys and join keys) |
| append | shared shape with a rayforce GAP - the module binds no append entry point (`ray_lazy_append` unbound) and the rayforce matrix denies `:append`. UNION ALL semantics: rows concatenated, position-aligned columns (NOT UNION BY NAME); a side whose column count or expression shape mismatches its siblings raises the expansion-time malformed-tree class naming the append node |
| from-parquet / write-parquet | `from-parquet` is shared; `write-parquet` is per-backend (duckdb serves it, rayforce DENIED - no parquet write surface). Both engines serve parquet read/write natively; rayforce's native-layout write is a rayforce extension (3.2); predicate pushdown is engine-internal optimisation, not surface |

The `where`, `join` and aggregate memberships are the highest-stakes
divergences in the table: `where` and `join` demote on null
semantics, and count-distinct/median demote on engine surface
availability. The 8.4 real-query set (section 7) carries the
where/join null-predicate, null-key and anti lanes as duckdb-only, or
waits on the rayforce slices named above.
rayforce slices named in section 3.2.

### 3.2 Per-backend extensions

Namespaced, opt-in, declared in the backend's compatibility matrix;
use against a non-declaring backend raises at expansion with operator
and backend named (section 5).

- **rayforce extensions**: pivot, asof and wco joins, the graph
  algorithm set, HNSW vector rerank and the running/moving aggregate
  families are ALL UNBOUND on janet-rayforce 0.1.1 - the engine ops
  exist in the vendored headers but the published module binds none of
  them, and this contract's backend is a thin translator over the
  module, so they are unreachable in v1. The v1 rayforce matrix
  declares only where-as-filter (two-valued nulls) and join
  inner/left/full (null-matching keys). Each unbound op is a named
  rayforce gap pending its janet-rayforce slice.
- **duckdb extensions**: correlated subqueries and recursive CTEs via
  the escape hatch (3.4 - the bind-shape promotion is closed: ray_in
  unbound, ray_if subgraph branches rejected by the engine); asof
  (native ASOF JOIN; the rayforce half is unbound); window frames and
  moving aggregates (served on duckdb; ray msum/mavg unbound);
  count-distinct and median/quantile aggregates; renamed select
  outputs; integer idiv/mod (truncated; rayforce floors). Duckdb has
  no plan-level counterpart to the graph algorithms or HNSW.
- **Promotion candidates**: asof (rayforce side unbound), moving
  aggregates (unbound), correlated subquery bind shape (unbound +
  engine nyi). Each re-opens only when a janet-rayforce slice binds the
  named op; promotion never happens silently.

### 3.3 The expression surface

Scalar expression nodes follow the rayforce OP_ opcode table as the
reference list: arithmetic, math, comparison, logic, strings, temporal
(extract/date_trunc), cast, if, isnull, in/not-in, min2/max2. The duckdb
SQL render must cover the same surface; where SQL covers an operator
differently the requirement is same semantics with the divergence stated
in the renderer's contract notes. Shared expressions
are arithmetic (add/sub/mul), float div, comparisons, logic and
isnull/min2/max2/if on non-null lanes; integer idiv/mod are
per-backend (rayforce floors, duckdb truncates); in/not-in is
per-backend (ray_in unbound on rayforce); NaN lanes are excluded
(distinct, group keys, join keys diverge by construction under the
engine's unified mapping). Non-finite results: duckdb carries IEEE
infinities; rayforce nulls them by design (intentional single-null-sentinel
model; overflow is indistinguishable
from missing data on the rayforce side). Shared-surface expressions
must not rely on non-finite results: an expression whose overflow
produces a non-finite value returns `inf` on duckdb and `nil` on
rayforce - a documented per-backend divergence (the fixture's value
ranges avoid manufacturing it; if a real query needs it, the operator
demotes per the intersection rule).

### 3.4 Escape hatches (the documented exception to no-SQL-parsing)

One constructor, backend-tagged: `(escape :duckdb "...")` emits a SQL
fragment verbatim at a defined position; `(escape :rayforce handle)`
splices a pre-built graph/op handle from janet-rayforce at a defined
position. Non-portable by construction: a query containing an escape
node renders on exactly its tagged backend and raises the
extension-denial shape at expansion on every other. The backend tag
is explicit at the call site, so the non-portability is visible there.

### 3.5 Gaps, named as gaps

| gap | status |
|---|---|
| window | a window node is denied by every backend in v1 - `ray_window_op` is unbound on janet-rayforce 0.1.1; present in the grammar, absent from v1 capability. The frame enums are recorded from the vendored headers (RAY_FRAME_ROWS/RANGE 0/1; RAY_BOUND_* 0-4) for the janet-rayforce slice that binds the op |
| Bind (correlated subquery) | not expressible on rayforce - ray_in unbound, ray_if subgraph-op branches construct but the engine rejects them downstream (nyi / length mismatch); duckdb reaches them through the escape hatch |
| With (named CTE) | cost per consumer (ray_lazy_wrap/materialize unbound); a two-consumer With executes its body twice on rayforce, stated with the cost implication in the compatibility matrix and README |
| Iterate (recursive CTE) | out of scope; rayforce graph algorithms cover the common cases natively, duckdb reaches them through the escape hatch |

The classification table above is the ONLY contract section that
re-opens on engine evidence; everything else changes by versioned
revision (section 10).

## 4. The backend contract

A backend is three things:

1. **A renderer**: node tree -> engine-native form (SQL text for
   duckdb; op-plan DAG construction for rayforce).
2. **A catalog**: the schema description (table names, columns,
   types, nullability), authored once and shared across backends;
   the Chinook fixture (section 7) is its source of truth. Optional
   per query: without it, expansion skips name checks and the engine
   is the only validator.
3. **An execute function**: rendered form -> the section 2 result
   wrapper, via the engine module's existing path.

Backend BINDING is separate from schema: bindings are per-backend
facts attached to data sources - a parquet path binds any backend, a
duckdb-registered view binds duckdb, a rayforce table handle binds
rayforce - resolved from the from-node's source type. Never a second
hand-maintained catalog: two catalogs drift, and the intersection
rule cannot see the divergence.

What the catalog checks, and where the tree pass fences:

- **Parquet sources.** A parquet source is
  catalogued under its SOURCE KEY: the `from-parquet` path, or the
  node's `:alias` when it carries one. When the catalog names that
  key, its columns are checked exactly like a table's. When the key
  is absent, the name check is skipped and the engine remains the
  only validator - the source is unnamed, not unknown. Columns of that
  source's projection are still reported.
- **Alias-qualified references.** A column reference
  carrying `:alias` resolves through the alias table built from the
  tree's sources; it is checked against its source's columns like a
  bare reference. An alias no source in the tree carries raises
  `:unknown-column` naming the alias. Source collection is a pass of
  its own, so a reference is resolved against the whole tree rather
  than against whatever the walk happened to visit first.
- **Nested `:query`.** A `:query` node wraps a tree
  (`:tree`) and is TRANSPARENT at the top level: the tree pass walks
  into it, so `:node-types` covers the subtree and a denial names a
  real operator, never `:query`. A `:query` node in an operand slot
  (`:input`, `:left`, `:right`, `:sides`) is malformed: it raises
  `{:error :malformed-tree :why :query-not-input}`.
- **Cyclic trees.** Every pre-selection walk
  refuses cycles. Identity is an ANCESTOR PATH, not a global visited
  set: a value reached twice through an alias is a shared value (legal,
  visited once); a value reached from itself is a cycle
  (`{:error :malformed-tree :why :cyclic-tree}`). Sibling nodes with
  equal content are never cycles - comparison is by identity, not
  content.
- **Inert data.** Mutable arrays on node slots are
  frozen to tuples at the tree pass, and validation validates the
  frozen copy. A caller mutating its own array after expansion cannot
  change the expanded tree or any render of it.
- **Nested array projections.** A select column that is
  indexed but is not a valid column/expression raises
  `{:error :malformed-tree :why :select-col-type}` at the tree pass,
  before render. Renderers additionally refuse to quote any identifier
  that is not a keyword or a string, so an opaque reference can never
  reach the engine as SQL text.

### 4.1 Registration

A new backend is a module that conforms to this contract. Registration
is explicit, never discovered - no $JANET_PATH scanning (a scan imports
modules with import-time side effects and makes an absent translator a
silent miss; with explicit registration a missing translator is a
named, actionable error at the point of use):

```
(register-backend! @{:name :duckdb
                     :renderer <fn>       # node tree -> engine form
                     :execute <fn>        # engine form -> result wrapper
                     :catalog-spec <spec>
                     :matrix <compatibility matrix>})
```

- The table is VALIDATED AT REGISTRATION: every key required;
  `:matrix` well-formedness (every matrix key a known node type;
  every shared-set operator declared) and name uniqueness checked
  before the registration takes.
- **Duplicate `:name`** raises the registration error class, naming
  the backend.
- **Malformed matrix** (unknown operator key, or a shared operator
  left undeclared) raises the registration error class, naming the
  matrix entry.
- Alternatively the user passes the translator to `defquery` /
  `execute` explicitly, per query.
- No core-code changes, no engine-module changes ride on a new
  backend.

### 4.2 The translator interface

- **MUST-translate nodes**: the shared node set (3.1). A backend that
  cannot translate one of these is not a backend.
- **MAY-extension nodes**: nodes a backend serves beyond the shared
  set, declared in its compatibility matrix (per operator, per
  backend, data not prose).
- **Extension denial**: a node the backend does not declare raises at
  expansion time - before any rendering or execution - naming both
  the offending operator and the backend. When SEVERAL operators in a
  tree are undeclared, the named operator is the FIRST undeclared one
  in expansion order (base node before variant/escape lanes); the rule
  is deterministic and the denial names exactly one operator and one
  backend.

### 4.3 Backend selection precedence (no default, ever)

Resolved per execution, in order:

1. Explicit: `(execute q :backend :duckdb | :rayforce)`.
2. Inference from handle provenance: the data-source bindings the
   from-nodes carry. HANDLES COMMIT BACKENDS - a query bound to
   duckdb-registered views serves duckdb; a rayforce table handle
   serves rayforce (this inference row applies
   to NON-HANDLE sources only - a from-node whose source IS a handle
   without a :backend key never reaches selection; it raises
   :handle-without-backend at the tree pass). CATALOGS DO NOT - a
   catalog is schema description, shared across backends, and never
   selects one.
3. Otherwise a named error, `{:error :backend-ambiguous}`.

A default backend would hide which translator served the query; there
is none. `render` takes `:backend` under the same rule: its purpose is
showing what one backend will do; a backend-less render is
meaningless.

If the explicit `:backend` and the provenance-inferred backend
disagree, the query never executes: the conflict raises
`{:error :backend-conflict}` carrying both backends (property (e) of
specs/intersection.qnt).

The error classes around selection, and the guard's shape:

- **One disagreement, one class.**
  `:backend-ambiguous` is raised whenever provenance is EMPTY or
  MULTI-VALUED - independent of call shape (with or without an
  explicit `:backend`). `:handle-without-backend` is reserved for a
  handle source that carries no `:backend` key at all, detected at the
  tree pass. A class never depends on how the call was spelled.
- **Unregistered handle.** A source handle whose
  `:backend` names no registered backend raises
  `{:error :unknown-backend :backend <b>}` at selection. It never
  reaches `:internal`.
- **String backends (class split).** A source whose `:backend` is a
  string is not a backend name: it reports `:unknown-backend` rather
  than joining a conflict.
- **The cross-backend guard names all backends.** A tree whose sources resolve to more than one distinct
  backend raises `{:error :malformed-tree :why :cross-backend-handles}`
  with `:node` (the last provenance node the walk visited), `:why` and
  `:backends` - the full sorted, de-duplicated list. The guard reads
  provenance from from-nodes AND from from-parquet nodes (their `:src`
  handle carries the backend), so a parquet source cannot slip past it. This is a `:malformed-tree` class, not `:backend-conflict`:
  the tree is ill-shaped for one execution. `:backend-conflict` remains
  reserved for explicit `:backend` versus provenance-inferred backend.

### 4.4 The duckdb renderer's requirements

HoneySQL-school SQL render: dialect-aware quoting, one node -> one
clause, whitespace-stable output. Parameter binding for literals:
every literal in the tree becomes a bound parameter, never
interpolated SQL text - injection-shaped values are data end to end.
NULL/NaN/type mapping follows janet-duckdb's published conventions
(contract v1.4). A from-node binds one of: a parquet path (renders
`read_parquet('...')`), or a table created by SQL DDL on the renderer's
connection (named in the catalog; lifetime is the connection - a dropped
table fails at execute with the db catalog error, including for statements
prepared before the drop, and a deleted parquet path fails at execute with
the IO error; no registered-view API exists on janet-duckdb 0.1.2, so a
registered-dataset binding is not offered). The renderer must hold the
connection open
across prepare/render/execute. janet-duckdb itself takes no changes for
this module - publication acceptance includes verifying that no
janet-duckdb release is required to ship janet-query.

### 4.5 The rayforce backend's requirements

The backend inherits janet-rayforce's published contract (v1.0 +
A1-A12) as its ownership and error discipline: handle provenance
fences, the null mapping (including the A2 unified f64 NaN/null
lane), deferred types fail loud, threading rules, version coupling.
The backend is a thin translator onto janet-rayforce's existing
functions - it adds no ffi surface of its own. Write-side type
discipline for the parquet reader (flat primitives, null-free PLAIN
per rayforce contract A5) is a backend requirement, not an engine
hope.

## 5. Error taxonomy

One grammar across the module; every raise is a struct carrying an
`:error` keyword:

| error | shape | raised |
|---|---|---|
| `:backend-conflict` | `{:error :backend-conflict :explicit <b> :inferred <b>}` | explicit `:backend` and provenance-inferred backend disagree, at selection, before expansion |
| `:unknown-backend` | `{:error :unknown-backend :backend <b>}` | an explicit `:backend` names a backend that is not registered, at selection, before expansion |
| `:backend-ambiguous` | `{:error :backend-ambiguous}` | neither explicit backend nor inferable provenance |
| extension denial | `{:error :extension-denied :operator <op> :backend <b>}` | a node the selected backend does not declare, at expansion, before any render/execute; escape nodes denied off-tag hit this same shape |
| malformed tree | `{:error :malformed-tree :node <node> :why <why>}` | forged or ill-shaped trees, at expansion (the tree is ordinary Janet data, testable without an engine); the cross-backend-handles shape raises the same class BEFORE expansion |
| expansion name error | `{:error :unknown-table / :unknown-column :name <name>}` | catalog present, name not in it; honoured on BOTH the render and the execute path. `<name>` is a keyword in every lane, whichever form the caller wrote |
| registration errors | duplicate `:name` / malformed `:matrix` (4.1) | at `register-backend!` |

### 5.1 The per-backend error-class asymmetry (documented)

The same bad query produces different error classes per backend; the
contract states which class the user sees (the layer adds expansion
errors on top, it never replaces the engine oracle - the SQL render
is syntax-shaped only, duckdb's parser is the final oracle on its
side, rayforce's plan-build on its):

| failure type | duckdb | rayforce |
|---|---|---|
| unknown table/column (catalog absent) | db error at execute (parse/resolve) | plan-build error at execute |
| unknown table/column (catalog present) | expansion-time error | expansion-time error |
| type error in an expression | db error at execute | engine error at execute (e.g. a non-boolean filter pred raises "WHERE must produce a bool mask or truthy scalar" at execute, not plan-build; wrapper-fenced misuse raises at plan-build) |
| unsupported operator (not declared) | expansion-time error, operator + backend named | same |
| malformed node tree | expansion-time error, node named | same |

The rayforce columns are measured across 30 misuse lanes: all error
atoms, no crash, and the execution-scope alignment gaps documented
below. Two renderer-mandatory alignment fences follow from them: the
module does NOT fence
a filter pred or group agg input drawn from a different-length column
(filter silently returns the full input; group raises a misattributed
decode error) - the rayforce renderer must guarantee pred/agg input
row-scope itself.

The escape lanes to the raw engine error close as follows. With a catalog present, a
stored reference out of scope is an expansion error; a qualified reference is
judged by its qualifier; a join key naming a column of the wrong arm
(or of neither) is an expansion error, in keyword and string form
alike; a renamed `:as` projection is reported and checked under its
output name; a selector above a group is judged against the group's
outputs; and two sources naming one alias are refused with
`:why :duplicate-alias`. The following lanes deliberately still DEFER
to the engine oracle, and a caller-supplied catalog does not narrow
them: a direct `from-parquet` source, and an append side that is one
(an unnamed source is unnamed, not unknown); any arm whose outputs are
not computable; and a column named by a join's own key where an arm is
unnamed. A join whose arm is a CATALOGUED parquet source is
determinable and is checked.

## 6. Ordering and equivalence semantics

- Row order is significant ONLY when the tree ends in an `order` node.
  Without one, each engine returns rows in whatever order its
  execution produces and the two may differ: equivalence checking
  (tests, 8.2.2, 8.4) is order-insensitive for unordered queries,
  order-sensitive for ordered ones.
- Ties: a sort key that does not totally order the rows leaves
  TIE-GROUPS - rows sharing identical sort-key values are
  interchangeable, and equivalence comparison is a multiset
  comparison within tie-groups. Row order itself is significant only
  when the order node's key is total (no ties possible).
- Column order follows the projection (section 2).

## 7. The coverage manifest and the demotion trigger

- **The coverage manifest** is the operator x edge-class table per
  backend: for every operator in the node set and every registered
  backend, which equivalence edges (NULL keys, empty inputs, mixed
  types, error lanes) the 8.2.1 cells exercise. It is data, shipped
  with the module, and the single source the compatibility matrices
  and the test plan are checked against.
- **The demotion trigger**: if an engine change demotes an
  operator out of the shared set, and that operator is named in any
  committed 8.4 real-query set query, a requirements revision lands
  naming the affected queries and their substitutions. A demotion
  event with zero affected queries needs no revision. Quint property
  (d) (specs/intersection.qnt) checks this consistency: a demotion
  event consistent with the manifest implies zero affected queries
  or a recorded revision.
- **The 8.4 real-query set**: a minimum of 10 real
  queries (~12-15) run against BOTH backends, each producing the same
  result, exercising the entire API surface; each oracled against
  raw SQL for duckdb and the rayforce-native query for rayforce.
  Dataset: Chinook, vendored in-repo (schema script + generated
  Parquet export both engines load natively), with a controlled NULL
  set injected on top. 6-8 queries adapted from the classic Chinook
  teaching coverage as a coverage checklist (mined, not copied), 5-7
  original hitting window frames, moving aggregates, asof joins,
  pivot, anti-join, count-distinct with NULLs, date-partition
  grouping. The query list is the test plan's deliverable.

## 8. Version coupling

The same pin discipline as the engine modules:

| component | pin |
|---|---|
| janet-duckdb | published 0.1.2, api-contract v1.4 |
| janet-rayforce | 0.1.1, api-contract v1.0 + addenda A1-A14 |
| janet-num | the packed-buffer seam (shape/byte-count guard) |
| RayforceDB | v2.11.5 (vendored, content-hash pinned headers) |
| libduckdb | 1.5.6 |

A bump on any engine pin requires re-probing the affected
rows and re-passing this contract.

## 9. Reference scope

A reference is decided by the ROW ITS IMMEDIATE INPUT PUBLISHES, never by a
lane label attached to a node below it. Those rules are stated in full in
section 11 and modelled in `specs/scope-model.qnt`.

## 10. Change protocol + stamp

This contract changes by versioned revision: a revision names the
sections it changes and carries the final sentence for each changed
rule. Superseded sentences do not remain in the text. The checked arm of
the intersection rule is `specs/intersection.qnt`; the reference scope
machine is `specs/scope-model.qnt`; the catalogue lanes are
`specs/catalogue-record.qnt`, `specs/catalogue-shapes.qnt` and
`specs/catalogue-partb.qnt`. The empirical arm is the 8.2.2/8.4
equivalence suites.

v1.1, 2026-11-05, writer-identity amendment - the writer-identity field
and its additivity guarantee, the identity-scoped admissibility rule, the
resolver contract's key, set and disposition rules, the absent-mode
known limitations and the exclusions register.

## 11. The published projection and reference scope

A reference is judged against the ROW ITS IMMEDIATE INPUT PUBLISHES. Four
rules, all readable from one row value:

- (i) the row is the nearest RESHAPING node's output: a join (the union
  of its arms, whatever the arms are - a parquet arm is unnamed whether
  or not the caller catalogued it), an append (the positional alignment),
  a group (keys + computed);
- (ii) a pass-through (`where`, `limit`, `order`, `distinct`, `select`
  with no declaration, a `query` wrapper) does not reshape: the row is
  the one beneath it, at ANY distance;
- (iii) a SELECT that declares a projection publishes EXACTLY it - the
  entry form (bare keyword, get expression, string) is irrelevant. A
  select that declares nothing publishes nothing: it is a pass-through,
  and its row is the one beneath;
- (iv) two selects in a chain each publish their own projection, so an
  outer projection that names a column the inner does not publish is
  refused at the OUTER select - the chain-launder prohibition.

The published row is independent of the caller's catalog: the catalog
says which columns an arm supplies (so a real column is SERVED, never
refused), not whether the arm is unnamed (so cataloguing an alias changes
no verdict).

### 11.1 Input scope for stored references

A stored (non-exempt) reference must appear in the referencing node's OWN
input outputs. It is refused when that scope is DETERMINABLE, meaning the
input's outputs are computable under `output-columns` and every source on
that data path is catalogued. The rule narrows only: a reference that IS
in scope still faces the per-source check, so the lane can refuse more
than the per-source check alone and never accepts more.

- A join has no `:input`. Its operands are `:left`/`:right`, and a key
  names a column of BOTH arms, so the scope of a join's or asof's own
  references is the UNION of its arm outputs. An arm's references remain
  scoped to the ARM: an arm is never judged against the join's key list.
- Order of rules, per reference: the computed-name exemption, then the
  input-scope rule where determinable, then the per-source
  every-candidate OR named-source resolution. The input-scope rule
  replaces the per-source resolution only where the scope is
  determinable.
- An undeterminable scope (an uncatalogued base, an unnamed parquet
  source, an undecidable shape) defers to the per-source rules and the
  engine oracle. A source that is UNNAMED is unnamed, not unknown.
- The binding set for an unqualified reference is the sources beneath the
  referencing node: `:input` (and a query wrapper's `:tree`) for a
  selector, the arms for a join, asof or append. A sibling arm of a join
  further up is not on that path and is not asked for the name.

### 11.2 The computed-name exemption

A reference is exempt when the node MAKING the reference produces the
name from its own input: the nearest operator beneath the reference, and
the pass-through operators (`order`, `limit`, `distinct`) that forward
that input's names. "Beneath the reference" means the reference's data
path, never the whole tree. A name computed in a REPLACED subtree, or by
the far arm of a join, exempts nothing; a join or append REPOSITIONS its
arms, so a name an arm computes is visible at the join itself.

A computed name is never an arm-union name: a stored column of one append
side and a sibling arm's aggregate do not exempt a name. The catalog's
columns and the tree's computed columns are both accepted.

### 11.3 Name resolution, per source

Section 5's expansion-time name check is defined per source, not against
a tree-global union of columns, and a tree's own computed output is never
a source column. A reference resolves in one of three ways:

- **Computed name.** A name the tree itself PRODUCES beneath the
  reference - a group's aggregate alias (`sum_pay` from
  `(group ... (sum (get :pay)))`) or a select expression name - is not a
  source reference at all; the catalog has no say and it passes.
- **Alias-qualified stored name.** Checked against the catalog entry of
  exactly the source that alias names, never against a sibling's columns.
- **Unqualified stored name.** Requires EVERY candidate source to name it
  (the every-candidate reading of "checked against every catalogued
  source it could come from"). A column named by only one of two
  catalogued sources is refused, naming that column, and a computed name
  never widens this lane. An uncatalogued source (a parquet path with no
  entry, a parquet alias with no entry) defers the whole reference to the
  engine oracle: a catalogued table never poisons an uncatalogued parquet
  source's columns.

### 11.4 The merged join row

A join or asof produces the concatenation of both arm outputs, and a
selector above a join is judged against that UNION:
`select(join(t, u), :z)` is legal whenever `:z` is a column of either
arm. The union applies at the join boundary only: a select's own
projection is an ECHO, never a scope, so a name the input does not supply
is refused even though the select lists it. No operator other than a
join/asof widens the scope this way.

Join keys are checked PER SIDE: each left key must name a column of the
LEFT arm's outputs and each right key a column of the RIGHT arm's. A key
naming a column of neither arm, or of the other arm only, is an
`:unknown-column` expansion error instead of a silent pass to the engine.
The check runs only where that arm's outputs are computable; an
undeterminable arm defers. Both forms of a key - keyword and string -
reach the same verdict.

An append's row is positional: a side whose columns are not computable
poisons the union rather than coercing to the empty set, and a nil arm
poisons a join's union the same way. A coerced empty set would read as
"every name is out of scope"; the correct verdict is a deferral.

### 11.5 Deferral

A deferral is a postponement, never an exemption. A reference deferred at
an inner undeterminable node and re-emitted above a join whose named arms
all lack it AND which no catalogued source mentions is refused there. A
name some arm may own still defers: the false-refusal rule wins.

DEFERRAL IS SCOPED TO PRE-PUBLISH SCOPE. The licence to defer exists only
where NO ROW HAS BEEN PUBLISHED yet. Once a node publishes a projection
the reference is JUDGED: served where a proven supplier backs a name the
row carries, refused otherwise. A reference is never both deferred and
refused at its own node; a reference deferred at one node and refused by
the ceiling above it is two nodes, one reference.

A qualified reference whose qualifier names an uncatalogued source
defers, and that judgement runs before any re-emission rule.

### 11.6 The published projection

A selector over an unnamed (parquet, unresolvable) arm publishes its own
projection: a `select` whose input is a join with an unnamed arm reports
exactly its own `:cols` entries as its output columns, with each
expression entry reported under its `:as`/`:alias`. The join's own
undeterminability is unchanged by this: a bare unnamed join with no
`select` above it keeps its deferral.

A published projection is a REFUSAL BOUNDARY, never an existence proof:

- A reference the projection does not name is refused
  (`:unknown-column`) instead of deferred.
- A reference the projection DOES name is not thereby proved to exist:
  it routes to the pre-existing lanes (per-source checks, deferral
  re-emission), which prove the column where they can and refuse or defer
  where they cannot. A projection entry vouching for its own name would
  let an unknown column launder through any chain of selects, each one
  vouching for the next.
- The lane is bounded by the selector's published projection - full stop.
  The caller's catalog (whether or not it names a parquet alias), the
  join's key list, and any chain of wrapper nodes between the selector
  and the reference do NOT bound the lane. A reference is refused iff it
  is outside the published projection and inside no other exempt lane; it
  defers iff the published scope is genuinely undeterminable; it is served
  iff the published projection or a proven lane supplies it. Pass-through
  chains of any length preserve the union.

A published name needs a PROVEN SUPPLIER: the node's own computation, the
input subtree's outputs, or an arm's outputs for a join. A projection
entry says what the row is CALLED, not that anything produces the column,
so a select that names a column no lane proves is refused with
`:unknown-column`, and a chain of projections cannot vouch for each
other.

A select that declares nothing forwards its input's row: its reported
output columns are its input's, never the empty list. An absent list is
an absent declaration, and where the input's columns are themselves
undeterminable (an uncatalogued parquet base) the pass-through stays
undeterminable and the reference defers.

### 11.7 The group boundary

A group's published row is its keys plus one name per aggregate, and
nothing else. A reference judged above the group at any distance wears
exactly that row, so the aggregate's ARGUMENT can never decide it: an
aggregate's argument is a reference inside the group's own scope and
never enters the outer walk.

REFUSAL AUTHORITY above a group: the SELECTOR is the only node that may
refuse a row-lacking name at every distance. `order` over a group refuses
any name the row lacks; `where` over a group defers when the group stands
above an unnamed arm and refuses a row-lacking name otherwise. Those
group-lane refusals are the pinned behaviour; they exist only below the
selector distance. A group's own aggregate-argument refusal (a name the
arm does not supply) is a required verdict.

ONE VERDICT PER TREE: the two lanes are disjoint and each wears its own
row - the inside reference wears the group's input union, the one above
wears the group's published row, and neither reading depends on the other
having run.

### 11.8 The undecidable row

When the identity test cannot decide an owner and every arm's record is
readable, the described-union row decides: carried names serve, unknown
names refuse. A read-failed arm is not this state - it keeps the open row
and defers.

On the identity-undecidable shape, the establishment of an arm's
description is the id-free ENTRY read (`catalog-entries` with no identity
map), and the shared-block guard is the discriminator between described
and undescribed: the guard fires, the arm is undescribed; it does not
fire, the arm is described by its entries. Wherever the identity test CAN
answer, the shared-block rule holds as stated in 12.4 and the arm's `nil`
stands.

This rule has no preimage in `specs/scope-model.qnt`: the model's
`source-columns` walk makes nil any entry under a key that is no arm's
own, so the shape the contract states here is pinned by suite cells
rather than by a model limb.

### 11.9 The rowless lane

When a select's target falls to the rowless lane, that lane owns NOTHING
on a readable row. The lane's two answers are "answerable" (a
published-column witness) and "silent" (no witness), and a third lane
answer exists - "unproven" (`:noproof`), a name the input's row CARRIES
with no proof path, reachable through a rename over a join arm. None of
the three may decide a readable row's target: on a readable row the
verdict is the row's membership, and a name the row lacks is REFUSED. The
lane is authoritative only where no row exists or the row cannot be read,
and there its answer is the deferral.

### 11.10 Witnesses and exemptions

- **A join key is a mention.** Where an arm is unnamed, a column named by
  the join's own `:lkeys` or `:rkeys` is deferred, not refused: the key
  declares that an arm owns the name. A name no arm supplies and no
  catalogued source mentions is still refused. The deferral is a
  postponement only: the select's own projection stays known.
- **An unqualified reference with no recorded source is still a
  reference.** A reference that binds to no source leaves an empty
  candidate list, and an empty list is an empty lane - the per-source
  conjunction is never consulted for it.
- **A qualified reference is judged by its QUALIFIER** before any
  re-emission rule: refused when the qualifier's source is catalogued and
  lacks the column, served when it has it, deferred where the qualifier's
  source is unknown or uncatalogued.
- **The where slot accepts any predicate expression.** A predicate whose
  leaves are all constants is SERVED without a name check - a constant
  predicate is legal SQL and the engine oracle accepts it. Only a
  predicate that is not an expression node refuses, with
  `:malformed-tree` / `:where-pred`. The `where` slot judges REFERENCES,
  not types: `WHERE 1` is served by the checker while the refusal of a
  non-boolean predicate is the engine's own decision. A scalar operand
  inside a predicate (`(gt (col2 :a) 5)`) refuses as a malformed
  expression.

## 12. The catalogue

The catalog decides UNION MEMBERSHIP - which columns a source contributes
- never a verdict on a reference.

### 12.1 One resolution mechanism

No site resolves a catalogue key by a single lookup. A source is queried
by EVERY key it answers to - its binding key, its canonical key and, for
a parquet arm, its path and its alias - and the three helper predicates
(`catalog-entries`, `source-columns`, `source-catalogued?`) are the only
way any lane reaches a catalogue entry. A caller's spelling of a key
therefore cannot decide a verdict.

`source-columns` answers an ordered list, not a set: an append is
position-aligned, so a side keeps the order its entry was catalogued
with. "The order its entry was catalogued with" is the order of the
entry's `:columns` list.

### 12.2 The arm record is the identity source

An arm's identity is the binding the tree carries: its node, its path for
a parquet arm, its alias when one is present, its source for a from arm.
Identity is a function of the tree alone and is CATALOGUE-INDEPENDENT. No
catalogue entry can create, move or destroy an arm's identity. The
catalogue answers one question only: which names the caller states the
arm contributes.

A catalogue setting can only ADD known-name information to an arm whose
identity the tree already establishes; it can never turn an unresolvable
reference into a resolvable one, nor the reverse. Concretely, for every
tree T, name n and catalogues C1 and C2: if C1 and C2 both name the same
source, the verdict on n above T is the SAME.

A string spelling and a keyword spelling of a column name denote one
name. The resolver normalises to the keyword form before any comparison,
at every surface that accepts one: select, the qualifier, the alias and
the join key-list. A bare struct entry with no `:alias` falls back to
`:col` - it names a column, it is not a rename.

### 12.3 The resolver's three functions

- `binding-key(arm)` - the key under which a record's columns are
  addressable.
- `keys(arm)` - the key SET: every spelling under which one record may
  be reached.
- `cell(arm, name)` - the verdict a reference gets at one name, judged at
  the arm's own cell.

1. **One answer is the answer.** The BINDING KEY of an arm is a single
   value, and `binding-key` is the only function that computes it. `keys`
   and `cell` DERIVE their answers from it or are deleted; no surface may
   compute a second binding key that agrees by convention. For a parquet
   arm the binding key is the record's alias when the record carries one
   and its path otherwise; for a from arm it is the arm's SOURCE. That
   asymmetry is licensed exactly once: a from arm is addressed by the
   tree, a parquet arm by its record.
2. **The key SET is the authority, the key SPELLING is not.** A setting
   written under any key in `keys(arm)` reaches the arm exactly as the
   canonical key does, and the verdict is the same for every such
   setting. A catalogue cannot move a verdict by choosing which of an
   arm's own spellings to write under.
3. **The columns disposition of a cell is a function of the STATE, not
   the key.** What a cell contributes is decided by WHICH SOURCE the tree
   has recorded for that reference, never by which key the reference was
   reached by. An unwritten reference reads as the canonical setting.
   Three dispositions:
   - `record` - an entry enumerates the arm: the arm's RECORD names the
     columns, and whether the entry's list is supplied at all is the only
     thing the entry decides.
   - `absorb` - the recorded source does not enumerate the arm (an absent
     entry, or a block that describes no arm): the record still names the
     columns, and the arm is NOT resolvable, so a name the record carries
     DEFERS. An entry may add known names; it may never add a serve.
   - `foreign` - the entry describes another source: the record is
     consulted and the entry contributes NOTHING. A catalogue cannot
     create, move or destroy an arm.
4. **The absorbed cell keeps the record's names.** Above an arm no entry
   enumerates, the entry contributes nothing and the RECORD alone names
   the cell, so the cell still carries the record's columns and a name
   the record carries defers rather than being refused. Disagreeing own
   entries are UNIONED: the catalogue does not decide column order or
   column membership.
5. **A join key is judged against record-derived columns only.** Each
   side of a join key is judged on its OWN side's cell, and each cell is
   judged where the arm is DESCRIBED. A join key naming a column both
   records carry is accepted; a name neither carries is refused; an arm's
   ALIAS is never a column of either side. The key's spelling cannot
   change the verdict, and an error may not name an alias that
   `binding-key` protects.
6. **A cell's verdict is decided by the reference alone.** One
   reference, one arm, one key, one verdict. No ancestor's inputs, no
   sibling's entry and no second spelling may enter the judgement.
7. **A non-sequence `:columns` misbehaves**: an entry whose `:columns`
   is present but is not a SEQUENCE OF NAMES does not describe a schema.
   A string or keyword value is iterated by byte, so the catalogue
   describes one-character columns the caller never wrote; a
   non-iterable value (an integer) raises Janet's raw host error instead
   of a contract refusal. Column names containing digits are unaffected -
   the type of the value is what matters, not the names. A tagged refusal
   for this shape is stated by the contract but not implemented.

The union of a resolvable cell combines the record names with the entry's
names. At a resolvable cell the two coincide (that identity is the
catalogue-independence rule), and at an absorb cell the cell takes the
defer branch before any per-name predicate runs, so the combination is
not observable as a separate rule.

### 12.4 The writer-identity field

A catalogue entry may carry a WRITER field naming the record the entry
was written for. The field's value is CALLER TESTIMONY about authorship:
the caller supplies it and the engine reads it; the engine never derives
it from the catalogue. The concrete keyword the implementation binds the
field to is the implementation's naming decision, not a contract fact.

**Absent field.** An entry that carries no writer field is governed by the
columns disposition and the block rules exactly as an entry on a surface
with no writer field at all; every pinned cell keeps its verdict. The
amendment is additive on the unamended surface. FIELDLESS IS A VALUE
test, not a testimony test: an entry is fieldless exactly when its writer
value is not one record name (absent, empty, list-valued, non-name or
naming no record all count as fieldless, and a name resolving to TWO
records counts as fieldless), and the fieldless lane reads no testimony,
because the value carries no single record name to testify for. The
fieldless lane therefore never reaches the admissibility rule below, and
the two cannot drift apart.

**The admissibility rule (entries carrying the field).** An entry that
carries a writer field contributes to a record's description only if all
three of the following hold:

- (i) **writer match** - its writer is that record. This is NECESSARY and
  is not by itself sufficient.
- (ii) **the key scoping** - the admitted entry sits under one of the
  record's own spellings. An entry under a key alien to the record is not
  admitted on identity alone.
- (iii) **the block rule** - a list carried under any key alien to the
  record silences the record's own entry carrying that list, whatever the
  alien entry's writer. The rule is decided by the LIST THE ALIEN ENTRY
  CARRIES, not by which record wrote the alien entry: the condition is one
  `not(e.cols.in(entryLists(cat, r)))` over every entry. The alien writer
  decides neither the marking nor the admission.

The walk that applies the letter is in `specs/catalogue-record.qnt`
(`unionPresent`); an independent-oracle restatement of the same rule is
in `specs/catalogue-partb.qnt` (`pbS2`). The oracle shares the key
scoping and the block rule with the walk by the letter's own design, so
it proves admission-shape conformance, not independent semantics.

**The A21.10 disposition reading.** The `foreign` disposition of 12.3
decides what an entry CONTRIBUTES where admission has not already ruled
on it. On the unamended surface that is every entry, and the consequence
recorded in 12.5 follows: the copy of a record's own list subtracts the
claim. On the amended surface admission decides first: the surviving set
of each description satisfies the block rule above, and once admission
has spoken the disposition has no surviving entry of a different writer
to describe a cell. Neither an alien entry's writer decides whether it
blocks (the block rule decides by content), nor does a silenced own
entry's writer decide whether it describes (it does not; the aliasing
leaf holds the list, and the own copy's writer adds nothing to a list
already carried elsewhere). This reading is a statement of scope. It
licenses no new behaviour: on the unamended surface nothing changes, and
on the amended surface admission carries the rule. It does not alter the
absent-mode baseline - under absent mode, disposition alone governs and
no admission rule applies.

**Circularity exception.** The columns disposition bars reading the
catalogue to infer which source an entry describes. Admissibility MAY
consult an entry's writer field, because the field is caller testimony
about authorship carried in the entry, not an inference the engine draws
from the catalogue. No other entry-resident fact is licensed; on entries
without the field the bar stands.

**S1.** When a record's own spellings carry two entries whose writer is
that record and whose column SETS differ, the arm is described by the
de-duplicated union of the two entries' columns and serves or refuses on
that union. The refuse reading (malformed, duplicate-schema class) is not
shipped: `malformed` is unreachable, and the union is the only behaviour.
Order-only disagreement - two entries carrying the same set in different
orders - is not this rule's trigger; it compares sets.

### 12.5 The absent-mode known limitations

Where no entry carries a writer field, three properties do not hold, and
their failure is the surface's behaviour rather than a defect:

- An alien or cross-record copy of a record's own column list subtracts
  that record's claim. On the `alien-copy` shape the description is
  `{c}` where the record's own entries claim `{a,b,c}`.
- A foreign entry under any of the record's own spellings (path or alias,
  string, keyword or symbol form) describes the record.
- Catalogue presence can flip a verdict, and the measured direction is
  subtractive: an alien entry may SUBTRACT a block, never ADD a name.
  Removing an alien entry can move a verdict, and removing one can never
  introduce a name.

Under the writer-identity field all three close: a shared block adds
nothing under identity scoping and, when the block it removes is the one
the block rule applies, it subtracts the record's own claim of that list;
a foreign entry under any of the record's own spellings describes
nothing; and removing every alien-key entry, or every entry whose writer
is another record, can change a description only where the removed entry
is the block the rule applies. The measurement's arrow runs from WRITER
match to ADMISSION (a list the writer carries does not make its entry
admitted), never from CONTENT to the writer disposition.

### 12.6 The exclusions register

The following surfaces are stated by no model and are therefore
UNSPECIFIED for this version:

- the ORDER of the union list (set semantics; it decides no verdict and
  is not caller-reachable - the append name-alignment advice applies);
- entries carrying an empty `:columns` list;
- from-source arms (pathless, outside the shared-block lane);
- two records sharing one name text (the ambiguity lane);
- the append width lane downstream of the described set;
- writers beyond the two-record domain.

Absence of a sentence is not permission.

### 12.7 Ordering across keys of one source

When two keys of ONE source carry DIFFERENT orders, the caller has stated
two incompatible schemas for one file and no order is preferred; the
entries are unioned and the disagreement is not visible in the published
column set. When the two entries carry the same names in the same order,
that is one arm catalogued twice and is accepted. The refusal for the
disagreeing case is not implemented and is carried as an open gap.

## Sources

- janet-rayforce's published contract (v1.0 + addenda A1-A14) - the
  contract the rayforce backend inherits, and the house contract
  template.
- janet-duckdb's published contract (v1.4) - the contract the duckdb
  renderer renders through.
- `specs/intersection.qnt` - the Quint model of the registration/denial
  machine, properties (a)-(e).
- `specs/scope-model.qnt` - the reference scope machine and the catalogue
  lane's property cluster.
- `specs/catalogue-record.qnt` - the walked catalogue model.
- `specs/catalogue-shapes.qnt` - the shape vocabulary the catalogue lanes
  import.
- `specs/catalogue-partb.qnt` - the writer-identity walk and its
  independent oracle.
