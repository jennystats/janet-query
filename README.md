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

`bench/` ships a deterministic scale generator (65,536 rows, seed 20261107,
sha256 recorded), three Janet routes, an output-equivalence-gated runner
and the protocol ([bench/PROTOCOL.md](bench/PROTOCOL.md)). Recorded runs,
min of five reps, same file, same machine:

| query | duckdb-sql cold | jq-duckdb cold | jq-rayforce cold | duckdb-sql warm | jq-duckdb warm | jq-rayforce warm |
|---|---|---|---|---|---|---|
| q1 filter | 5.3 | 8.9 | 29.6 | 2.9 | 6.2 | 1.3 |
| q2 group top N | 1.5 | 4.6 | 23.6 | 1.3 | 3.6 | 0.7 |
| q3 join | 4.4 | 11.0 | 24.5 | 4.0 | 8.5 | 2.8 |
| q4 top row per group | 3.8 | 10.9 | 26.4 | 3.2 | 7.8 | 3.0 |
| q5 full scan | 2.0 | 5.3 | 12.4 | 1.8 | 4.5 | 0.9 |

(ms; cold reads the file per rep, warm executes against loaded data.
Rayforce numbers after the execution-path fix - the pre-fix build paid
a per-execute cost of 800-2300 ms; see the janet-rayforce repo,
changes/fix-cr-execution-path-outcome.md.)

- Raw SQL through janet-duckdb and the tree layer on duckdb are the
  fastest routes, within 1.7x to 3.0x of raw SQL in both phases.
- The rayforce lane is now in the same band as duckdb: warm 0.7 to
  3.0 ms (faster than duckdb on q1/q2/q5), cold 12 to 30 ms (at the
  parquet-read floor). The full tree layer over the raw engine costs
  1.3x to 4.5x.
- The recorded tables in `bench/results/` also carry pandas, polars,
  dplyr and data.table numbers from the same comparison run; those
  route scripts are not shipped - they need toolchains beyond Janet.

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
libs/install-engines.sh   # libduckdb v1.5.6 + librayforce (engine 3.0.1), pinned and sha-verified
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
