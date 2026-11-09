# janet-query

Engine-agnostic compositional query trees for Janet. A query is an inert
Janet value; one of the registered backend translates it, checks it and executes
it. Two engines are currently available: [duckdb](https://duckdb.org) through
[janet-duckdb](https://github.com/jennystats/janet-duckdb) and
[rayforce](https://github.com/RayforceDB/rayforce) through
[janet-rayforce](https://github.com/jennystats/janet-rayforce).

Part of [Jenny Stats](https://github.com/jennystats), a home for Janet
data and statistics packages. Jenny is just Janet.

## What it is

- Queries are inert values (node structs) composed by `->` threading. No
  query text is built until a backend renders it.
- One query, one backend, per execution. There is no default backend; the
  backend is always named at `render` or `execute`.
- The core knows the node grammar, the shared-operator intersection rule
  and the error grammar - nothing about any engine. A backend is a
  translator (renderer, execute function, compatibility matrix) registered
  explicitly via `register-backend!`.
- With a caller-supplied catalogue, column names are checked before the
  engine is called. A name the catalogue does not carry is refused at
  translation with `{:error :unknown-column :name <n>}` - not discovered
  by the engine.
- Errors are values: every refusal raises a struct naming the fault, in
  the same grammar on both engines. Raw host errors never escape the
  wrapper.

## Example

```janet
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def q (-> (jq/from-parquet "chinook.parquet")
           (jq/where (jq/gt (jq/get :total) (jq/lit 300.0)))
           (jq/select :invoiceid :total)
           (jq/order [:total :desc] [:invoiceid :asc])
           (jq/limit 5)))

(jq/execute q :backend :duckdb)
```

The same tree runs unchanged on the other registered engine:

```janet
(jq/execute q :backend :rayforce)
```

Both return `{:rows @[(373 400.99) ...] :columns @[:invoiceid :total]}` for
the Chinook fixture shipped in `test/fixtures/chinook/`.

### Compose

```janet
(-> (jq/from-parquet "chinook.parquet")
    (jq/select :customerid)
    (jq/distinct)
    (jq/order [:customerid :asc])
    (jq/limit 5))
```

### Aggregate

```janet
(-> (jq/from-parquet "chinook.parquet")
    (jq/group [:customerid] (jq/sum (jq/get :total)))
    (jq/order [:sum_total :desc] [:customerid :asc])
    (jq/limit 3))
```

### Join

Join sides are projected to their numeric columns; a side carrying a
VARCHAR column is outside the rayforce join surface.

```janet
(def invoices (jq/select (jq/from-parquet "chinook.parquet") :invoiceid :reports_to))
(def managers (jq/distinct (jq/select (jq/from-parquet "chinook.parquet") :employeeid)))

(-> (jq/join invoices managers [:reports_to] [:employeeid] :left)
    (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
    (jq/order [:reports_to :asc]))
```

### Refuse early

With a catalogue, a name the description does not carry is refused before
the engine is called:

```janet
(def catalog {"chinook.parquet" {:columns [:invoiceid :total]
                                 :writer "chinook.parquet"}})
(jq/execute (jq/select (jq/from-parquet "chinook.parquet") :region)
            :backend :duckdb :catalog catalog)
# => {:error :unknown-column :name :region}
```

### Raw SQL or a tree

For a one-off query, raw SQL through janet-duckdb is the shorter route. Use the
tree when the query should run on more than one engine, when the catalogue
should check names before execution, or when the same query shape is
composed and reused.

The full example set, with captured output for every example, is in
[examples/EXAMPLES.md](examples/EXAMPLES.md).

## The behaviour contract

`execute` returns `{:rows @[(...) ...] :columns @[:k ...]}` or raises an
error struct. The full specification is in [specs/](specs/) - the
contract text in [specs/api-contract.md](specs/api-contract.md), and the
Quint models it is checked against. This section is the summary; the
spec is the authority.

The refusal grammar:

| error | class | raised when |
|---|---|---|
| `:malformed-tree` | shape | a node is not a struct, a slot carries the wrong kind, a cycle, a cross-backend handle mix (`:why :cross-backend-handles`), a misaligned reference (`:why :filter-pred-row-scope`, `:group-agg-row-scope`), a group argument that is not a column reference |
| `:extension-denied` | capability | an operator the backend's matrix does not serve: rayforce denies `:join-anti`, `:count-distinct`, `:median`, `:append`, `:write-parquet`, `:escape`, `:window`, `:asof` |
| `:unknown-column` | catalogue | a name the caller's catalogue does not describe for that source |
| `:unknown-backend` | provenance | a tree carrying a handle from a backend nobody registered |
| `:backend-conflict` | provenance | explicit backend and handle provenance disagree |
| `:internal` | wrapper | a backend returned a malformed result |

Rules the refusals follow:

- The catalogue decides UNION MEMBERSHIP - which columns a source
  contributes - never a verdict on a reference. A source the catalogue does
  not name defers to the engine rather than being refused.
- A catalogue entry may carry `:writer`, caller testimony that the engine
  reads and never derives. A writer-bearing entry describes the record its
  writer resolves to, in every spelling; entries are unioned per record, and
  the catalogue does not decide column order.
- Catalogue keys normalise: string, keyword and symbol spellings of one
  name describe the same entry; an entry's column list is compared as a
  set (order and duplicates do not matter).
- A projection is a refusal boundary, never an existence proof: a name a
  published row does not carry is refused above it; an undeterminable
  witness defers to the engine, never a coerced hit.

### Engine support

The measured matrix (every cell run, not assumed) is in
[bench/CAPABILITY-MATRIX.md](bench/CAPABILITY-MATRIX.md). Shape of it:

| | duckdb | rayforce |
|---|---|---|
| shared set: from, from-parquet, group, select, order, limit, distinct | serves | serves |
| where, join (inner/left/full) | serves | serves, per-backend semantics |
| append, write-parquet, join-anti, count-distinct, median, escape, asof, window | serves where noted | denied, named |

Both engines: cross-backend handle mixes refuse at composition; unknown
catalogued columns refuse before execution. Duckdb-only: append,
write-parquet, anti join, count-distinct, median, the escape hatch. The
rayforce surface additionally refuses VARCHAR beyond terminal positions
(`:rayforce-str-boundary`, `:rayforce-str-join-rename`) and keyless groups
(`:rayforce-no-keys-group`).

### Documented limitations

- The v1 node set has no window operator: rankings, running totals and
  per-group row numbers cannot be expressed as a janet-query tree. Two
  options: inject the SQL through the backend-tagged escape fragment
  (duckdb only - the query will not run on rayforce), or restructure as
  a group-and-join (the substitute the benchmarks' q4 uses).
- Order keys stay outside the catalogue name check (a known gap; a
  regression cell fails if a future change starts checking them silently).
- Group keys are name-checked at expansion.
- A catalogue entry whose `:columns` value is not a sequence of column
  names misbehaves: a string or keyword value iterates by byte (the
  catalogue describes nonsense one-character columns, silently), and a
  non-iterable value (e.g. an integer) raises janet's raw host error
  instead of a contract refusal. Column names containing digits are
  unaffected - the type of the value is what matters, not the names.
- The exclusions register - union order, empty `:columns`, from-source
  arms, the two-record same-path lane, append width, writers beyond two
  records - is outside the verified model and not licensed.
- CSV is not a tree-loadable source: the grammar has one file-source
  node (`from-parquet`), and a `.csv` path fails in the parquet reader
  with that reader's own error. Both engines read CSV natively, so the
  escape fragments reach it - `read_csv` on duckdb and the CSV
  reader on rayforce - but those queries run on one engine each, never
  on both.

### Existing data

Parquet files are the only file source a tree can name, but data
already living inside an engine is reachable too - per engine:

- **An existing duckdb database on disk**: the duckdb backend opens its
  own in-memory database and runs every tree there - it never opens a
  file directly. Attach your database through the exposed connection
  and its tables become ordinary sources:

  ```janet
  (import jennystats/query-duckdb :as jqd)
  (import jennystats/duckdb :as duckdb)
  (def conn (jqd/conn))
  (duckdb/execute conn "ATTACH 'mydata.duckdb' AS mydata")
  (duckdb/execute conn "USE mydata")
  # trees with (from :invoices) now execute against the attached file
  ```

  The connection is exposed as `jqd/conn`; janet-duckdb's full API
  (open, execute, prepared statements) works on it.

- **An existing rayforce table**: the rayforce from-node binds engine
  tables directly - a table already in the engine is wrapped in a
  source handle and borrowed, never copied:

  ```janet
  (from @{:backend :rayforce :handle my-table})
  ```

  An in-janet dataset takes the same shape with ordered
  `[name column]` pairs instead of a handle: `@{:backend :rayforce
  :columns @[@[:name col] ...]}`. Catalog-named tables are
  not bindable on rayforce (no named-table registry); handles and
  in-janet datasets are the two supported routes.

## Measured cost

`bench/` records a ten-route comparison over six queries at three scales:
65,536, 100,000 and 1,000,000 rows. Every route reads the same parquet file at
a scale with its own native reader. Cold reads the file inside the timed
region. Warm loads once, untimed, then times the query alone. Each cell is the
minimum of five runs after a discarded warm-up. The output-equivalence gate
compared every route's rows with raw SQL before any number was recorded, and
all three runs passed. The protocol, the fixtures and the per-cell record are
in [bench/PROTOCOL.md](bench/PROTOCOL.md).

Machine: x86_64, 4 vCPU, Intel Haswell, Linux, 2026-11-09. Times in
milliseconds, lower is better. Engines: DuckDB 1.5.6 through janet-duckdb
v1.5.6, and Rayforce engine 3.0.2 through janet-rayforce 0.1.4. Runtimes:
Janet 1.42.1, pandas 3.1.1, polars 2.1.0, R 4.5.0 (dplyr 1.2.1, data.table
1.18.6.1) and Julia 1.11.9 (DataFramesMeta 0.15.6, Query 1.2.0).

Queries: q1 filter and project (top 50), q2 group and sum (top 10), q3 join
and count, q4 top row per group, q5 full-scan aggregate, q6 high-cardinality
top 10.

### Against the other engines

The two janet-query backends next to pandas, polars, dplyr, data.table,
DataFramesMeta.jl and Query.jl. Cold rows first, then warm.

#### 65,536 rows

| query | phase | polars | pandas | dplyr | data.table | DataFramesMeta.jl | Query.jl | jq-duckdb | jq-rayforce |
|---|---|---|---|---|---|---|---|---|---|
| q1 | cold | 8.6 | 9.2 | 39.0 | 38.0 | 11.3 | 39.3 | 8.0 | 22.4 |
| q2 | cold | 9.9 | 9.5 | 41.0 | 45.0 | 6.9 | 46.1 | 3.6 | 14.8 |
| q3 | cold | 13.2 | 16.1 | 44.0 | 49.0 | 8.5 | 50.5 | 9.6 | 26.3 |
| q4 | cold | 14.6 | 14.2 | 56.0 | 55.0 | 9.2 | 88.7 | 10.3 | 25.4 |
| q5 | cold | 10.7 | 12.8 | 39.0 | 41.0 | 6.8 | 38.8 | 4.5 | 11.8 |
| q6 | cold | 22.9 | 22.3 | 881.0 | 54.0 | 18.3 | 111.4 | 13.1 | 15.4 |
| q1 | warm | 0.9 | 2.6 | 6.0 | 3.0 | 6.4 | 23.0 | 6.3 | 1.2 |
| q2 | warm | 2.1 | 3.5 | 9.0 | 6.0 | 0.9 | 40.8 | 3.4 | 0.6 |
| q3 | warm | 5.7 | 8.4 | 14.0 | 15.0 | 2.2 | 44.4 | 7.3 | 2.6 |
| q4 | warm | 3.7 | 8.6 | 17.0 | 11.0 | 2.7 | 81.6 | 7.3 | 2.2 |
| q5 | warm | 2.3 | 8.7 | 7.0 | 4.0 | 0.7 | 34.6 | 3.9 | 0.7 |
| q6 | warm | 12.5 | 15.7 | 860.0 | 11.0 | 11.2 | 91.2 | 12.7 | 5.4 |

#### 100,000 rows

| query | phase | polars | pandas | dplyr | data.table | DataFramesMeta.jl | Query.jl | jq-duckdb | jq-rayforce |
|---|---|---|---|---|---|---|---|---|---|
| q1 | cold | 13.0 | 14.4 | 53.0 | 48.0 | 17.6 | 41.9 | 8.3 | 28.1 |
| q2 | cold | 13.5 | 15.7 | 56.0 | 56.0 | 10.1 | 71.3 | 3.4 | 22.6 |
| q3 | cold | 12.7 | 25.0 | 67.0 | 84.0 | 14.2 | 88.5 | 9.4 | 44.3 |
| q4 | cold | 14.3 | 29.6 | 67.0 | 64.0 | 17.4 | 126.2 | 10.0 | 42.3 |
| q5 | cold | 13.7 | 25.4 | 59.0 | 61.0 | 11.3 | 71.0 | 4.6 | 19.4 |
| q6 | cold | 26.3 | 33.1 | 1480.0 | 87.0 | 32.2 | 189.9 | 14.8 | 25.4 |
| q1 | warm | 1.4 | 3.1 | 7.0 | 4.0 | 8.8 | 34.4 | 6.8 | 1.6 |
| q2 | warm | 2.6 | 3.2 | 10.0 | 8.0 | 0.8 | 61.0 | 5.0 | 0.7 |
| q3 | warm | 5.7 | 8.9 | 17.0 | 18.0 | 3.4 | 73.6 | 8.5 | 3.6 |
| q4 | warm | 6.1 | 10.5 | 22.0 | 16.0 | 4.6 | 109.3 | 8.9 | 3.4 |
| q5 | warm | 3.4 | 8.1 | 9.0 | 6.0 | 1.1 | 43.1 | 4.8 | 0.8 |
| q6 | warm | 14.6 | 19.0 | 1311.0 | 16.0 | 19.0 | 182.0 | 14.7 | 7.3 |

#### 1,000,000 rows

| query | phase | polars | pandas | dplyr | data.table | DataFramesMeta.jl | Query.jl | jq-duckdb | jq-rayforce |
|---|---|---|---|---|---|---|---|---|---|
| q1 | cold | 31.7 | 80.1 | 319.0 | 266.0 | 236.6 | 741.3 | 9.8 | 316.2 |
| q2 | cold | 23.9 | 63.3 | 294.0 | 284.0 | 123.9 | 1292.3 | 7.1 | 296.1 |
| q3 | cold | 36.9 | 98.9 | 318.0 | 420.0 | 152.5 | 1385.3 | 25.5 | 643.5 |
| q4 | cold | 35.5 | 96.6 | 424.0 | 486.0 | 237.8 | 1855.6 | 10.8 | 613.7 |
| q5 | cold | 33.3 | 86.4 | 233.0 | 307.0 | 166.8 | 1038.8 | 7.5 | 340.2 |
| q6 | cold | 163.7 | 206.1 | 13715.0 | 432.0 | 498.8 | 3339.2 | 46.8 | 356.2 |
| q1 | warm | 5.7 | 31.3 | 26.0 | 20.0 | 82.2 | 373.0 | 5.6 | 3.7 |
| q2 | warm | 3.5 | 18.1 | 56.0 | 60.0 | 21.0 | 1227.3 | 4.4 | 2.5 |
| q3 | warm | 21.0 | 49.9 | 99.0 | 144.0 | 34.3 | 932.6 | 13.2 | 22.1 |
| q4 | warm | 18.4 | 45.5 | 150.0 | 140.0 | 64.9 | 1898.6 | 8.1 | 15.2 |
| q5 | warm | 17.1 | 26.0 | 41.0 | 53.0 | 29.6 | 886.3 | 6.0 | 2.2 |
| q6 | warm | 133.9 | 147.8 | 13573.0 | 134.0 | 253.0 | 3427.5 | 46.9 | 67.5 |

### The layer against the raw engine

Each janet-query backend beside the engine it drives: raw SQL for DuckDB, the
engine's own Rayfall language for Rayforce. The gap is what the catalogue
layer costs on the same file in the same run.

#### 65,536 rows

| query | phase | duckdb-sql | jq-duckdb | rayfall | jq-rayforce |
|---|---|---|---|---|---|
| q1 | cold | 3.5 | 8.0 | 19.1 | 22.4 |
| q2 | cold | 1.5 | 3.6 | 18.2 | 14.8 |
| q3 | cold | 7.3 | 9.6 | 20.1 | 26.3 |
| q4 | cold | 3.3 | 10.3 | 17.5 | 25.4 |
| q5 | cold | 2.2 | 4.5 | 17.0 | 11.8 |
| q6 | cold | 9.0 | 13.1 | 21.7 | 15.4 |
| q1 | warm | 2.4 | 6.3 | 0.4 | 1.2 |
| q2 | warm | 1.1 | 3.4 | 0.2 | 0.6 |
| q3 | warm | 3.5 | 7.3 | 2.2 | 2.6 |
| q4 | warm | 2.0 | 7.3 | 1.4 | 2.2 |
| q5 | warm | 1.3 | 3.9 | 0.2 | 0.7 |
| q6 | warm | 9.1 | 12.7 | 4.7 | 5.4 |

#### 100,000 rows

| query | phase | duckdb-sql | jq-duckdb | rayfall | jq-rayforce |
|---|---|---|---|---|---|
| q1 | cold | 7.3 | 8.3 | 33.1 | 28.1 |
| q2 | cold | 2.6 | 3.4 | 31.3 | 22.6 |
| q3 | cold | 7.2 | 9.4 | 33.7 | 44.3 |
| q4 | cold | 5.2 | 10.0 | 32.4 | 42.3 |
| q5 | cold | 3.5 | 4.6 | 29.9 | 19.4 |
| q6 | cold | 16.8 | 14.8 | 35.3 | 25.4 |
| q1 | warm | 3.4 | 6.8 | 0.5 | 1.6 |
| q2 | warm | 1.5 | 5.0 | 0.2 | 0.7 |
| q3 | warm | 5.5 | 8.5 | 2.5 | 3.6 |
| q4 | warm | 3.4 | 8.9 | 1.8 | 3.4 |
| q5 | warm | 3.3 | 4.8 | 0.3 | 0.8 |
| q6 | warm | 13.8 | 14.7 | 6.5 | 7.3 |

#### 1,000,000 rows

| query | phase | duckdb-sql | jq-duckdb | rayfall | jq-rayforce |
|---|---|---|---|---|---|
| q1 | cold | 10.3 | 9.8 | 259.4 | 316.2 |
| q2 | cold | 6.6 | 7.1 | 239.7 | 296.1 |
| q3 | cold | 18.4 | 25.5 | 242.2 | 643.5 |
| q4 | cold | 7.2 | 10.8 | 248.7 | 613.7 |
| q5 | cold | 8.1 | 7.5 | 234.2 | 340.2 |
| q6 | cold | 53.3 | 46.8 | 304.3 | 356.2 |
| q1 | warm | 3.4 | 5.6 | 4.9 | 3.7 |
| q2 | warm | 2.9 | 4.4 | 1.3 | 2.5 |
| q3 | warm | 15.7 | 13.2 | 19.3 | 22.1 |
| q4 | warm | 5.1 | 8.1 | 11.7 | 15.2 |
| q5 | warm | 5.2 | 6.0 | 1.5 | 2.2 |
| q6 | warm | 47.5 | 46.9 | 61.5 | 67.5 |

### Reading the numbers

- Cold belongs to DuckDB and Polars. A DuckDB route is fastest in every
  cold cell at every scale. Polars beats the janet-query rayforce route on
  five of six cold queries at 65k and 100k, and on all six at 1M.
- Warm at 65k and 100k, Rayfall wins all twelve cells, from 0.2 to 6.5 ms.
  No janet-query route is faster on any warm query at either scale.
- Warm at 1M, the lead splits. Raw DuckDB SQL takes q1 (3.4 ms) and q4
  (5.1). Rayfall takes q2 (1.3) and q5 (1.5). janet-query on duckdb takes
  q3 (13.2) and q6 (46.9). The rayforce route leads no warm cell.
- On warm data, janet-query on rayforce is faster than Polars on five of
  six queries at every scale. The losses are q1 at 65k (1.2 against 0.9),
  q1 at 100k (1.6 against 1.4) and q3 at 1M (22.1 against 21.0). q6 is
  2.3x, 2.0x and 2.0x faster than Polars.
- On q6 the rayforce route sits within 1.15x of the raw engine warm: 5.4,
  7.3 and 67.5 ms against 4.7, 6.5 and 61.5. The group rows stay an engine
  segment instead of a Janet array.
- The layer cost on rayforce runs 0.8x to 1.9x of Rayfall at 1M warm. q1
  is faster through the layer (3.7 against 4.9); the rest read 1.1x to
  1.9x. At 65k and 100k the ratios run 1.1x to 3.5x, but cells under 4 ms
  sit at the timer's resolution.
- The duckdb layer costs more: warm, the tree runs 0.8x to 3.7x raw SQL.
  The gap is largest on the small cells and narrows to 0.8x to 1.6x at 1M.
- Peak memory is the whole process, read from VmHWM at exit. Cold, the
  four engine routes hold 78 to 504 MB, the four frame routes 187 to
  848 MB, and the two Julia routes 813 MB to 2.8 GB. Warm at 1M the
  janet-query rayforce route holds 354 MB against the raw engine's 325 MB.

## Which engine?

janet-query's two backends are different tools. Pick by data and
workload - and by preference, within what the data allows.

**DuckDB (janet-duckdb)** - the analytical default:

- Your data lives in parquet or CSV files, or in a `.duckdb` /
  `.sqlite` database file. DuckDB reads all of them directly, in
  place, with no ingest step.
- Ad-hoc analytical queries: scans, filters, joins, group-bys over
  tables too big to hold in memory comfortably. It spills to disk
  under memory pressure instead of failing.
- You want the fastest correct answer on the widest range of query
  shapes - a DuckDB route leads every cold cell at every scale in our
  measured tables (see Measured cost, above).

**Rayforce (janet-rayforce)** - the low-latency specialist:

- Your working set fits in RAM and is queried repeatedly - a live
  table queried many times, not a file read once. Warm runs are its
  territory: janet-query on rayforce beats Polars on five of six
  queries at every scale, and answers the filter, aggregate and
  full-scan queries under 5 ms at 1M rows. The high-cardinality top 10
  at 1M takes 67.5 ms, and the raw engine is the faster warm route at
  65k and 100k.
- Your data is already in a Rayforce splayed/partitioned table, or
  you control the ingest (its parquet reader is single-threaded and
  decode-bound; cold reads of large files are the one place the
  layer cannot help).
- You want a k/v-and-vector engine with a graph surface under the
  same process - the binding exposes the engine's DAG, not a
  subprocess.
- Size matters: DuckDB's engine is a 67 MB shared library; Rayforce's
  is 4.4 MB. For embedded use - one binary, small footprint, nothing
  to deploy alongside - Rayforce is the lighter dependency, and its
  deterministic single-binary build makes the footprint the whole
  cost.

**Either way**: the node tree, the refusal grammar and the error
contract are identical - switching is one keyword, and the
output-equivalence gate holds across both (verified per release).

## Alternatives

- **[doozer](https://git.sr.ht/~subsetpark/doozer)** - composable SQL
  queries for Janet, Ecto-inspired: inert data structures rendered to SQL
  for SQLite and PostgreSQL. janet-query is the same inert-tree idea aimed
  at analytical engines - the tree never renders to a dialect text, and the
  refusal grammar is verified before any engine call.
- **[declarative-dsls](https://codeberg.org/veqq/declarative-dsls)** -
  SQL-inspired select/join/sort syntax over in-memory dataframes, plus
  datalog and minikanren. Different substrate: Janet data structures, not
  external engines, and no parquet lane.
- **[suresql](https://github.com/joy-framework/suresql)** - yesql-style
  named SQL files as functions. Plain SQL as the interface, no tree to
  compose or cross-check.
- **[janet-duckdb](https://github.com/jennystats/janet-duckdb)** and
  **[janet-rayforce](https://github.com/jennystats/janet-rayforce)** -
  if you want a specific engine without the layer, both engines are
  usable directly: janet-duckdb takes SQL text (parameterised) straight
  to DuckDB, and janet-rayforce drives the engine in Rayfall, its own
  query language. janet-query exists for the layer on top of them: one
  inert node tree over both engines, one refusal grammar, one contract.

## Install

Requirements: Janet 1.42.1, and the two native engines:

```bash
libs/install-engines.sh   # libduckdb v1.5.6 + librayforce (engine 3.0.2), pinned and sha-verified
```

Then:

```bash
jpm install https://github.com/jennystats/janet-query
```

or import from a checkout by putting the repository root on `$JANET_PATH`.
All modules live under the `jennystats/` namespace: `(import
jennystats/query)`. The package vendors `jennystats/typed` (the docstring
and contract-guard module, also in
[janet-kit](https://github.com/jennystats/janet-kit)); janet-duckdb and
janet-rayforce are declared dependencies and install with it.

## Tests

```bash
./run_tests.sh
```

The core smoke is engine-free and always runs; the backend smokes and the
dual-engine Chinook acceptance suite (15 real queries, raw-SQL checked)
run when their engines are present - absent engines skip, present-but-
broken engines fail. The `test/fixtures/chinook/` fixture is deterministic
(Chinook-shaped, seed 20261020) and its bytes are re-verified against
`SHA256SUMS` before the first query.

## License

AGPLv3 - see `LICENSE`.

## AI assistance

The code in this repository was written with the assistance of a large
language model and reviewed by its maintainer.
