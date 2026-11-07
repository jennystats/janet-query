# Benchmark protocol

Three Janet routes run the same five queries over one parquet file; the
shipped runner measures them and gates on output equivalence before any
timing is reported. The recorded tables in `results/bench-run.out` and
`results/bench-run-b.out` were produced by a wider seven-route comparison
(raw SQL, the query tree on both engines, plus pandas, polars, dplyr and
data.table); the non-Janet route scripts are not shipped with this package -
they carry their own toolchain requirements - and their recorded numbers are
kept as measured context.

## Data

- File: `data/chinook-scale.parquet`, 65,536 rows, 4,576,710 bytes,
  sha256 `2ef33afa8127b9fae96d94dbb502fbfadb0a20a4d48fc5ced8cb19c8a8b2cfee`.
- Generator: `gen-data.janet`, seed `20261107`. Deterministic arithmetic, no
  PRNG state. Columns mirror the Chinook export used by the test suite
  (`invoiceid`, `customerid`, `invoicedate` epoch seconds, `total`,
  `country`, `employeeid`, `reports_to`, `lastname`), BIGINT ids, DOUBLE
  total, VARCHAR display strings, null-free, plain page encoding.
- Scale limit: the rayforce parquet reader decodes at most 65,536 rows per
  column. A 65,537-row file raises
  `rayforce: column total: expected number or nil, got array`. One shared
  file at that ceiling is the largest every route can read.
- Regenerate: `janet gen-data.janet` (defaults to the path above). The file
  is not committed; the seed and generator are.
- The test fixture (`test/fixtures/chinook/chinook.parquet` in this
  repository) is the small Chinook-shaped export used by the examples and the
  suite; this benchmark uses the generated scale file only. That fixture's
  provenance (published Chinook schema, deterministic seed) is recorded in
  its own README.
- The Chinook projection is one denormalised table, so the multi-table query
  shape is a self-join over two projections of the same file. The joined
  keys are real columns of the export (`reports_to` against `employeeid`,
  `customerid` against `customerid`).

## Shipped routes

| route | load path | file |
|---|---|---|
| duckdb-sql | parameterised `read_parquet` through janet-duckdb | `route-duckdb-sql.janet` |
| jq-duckdb | janet-query tree, duckdb backend | `route-jq.janet` |
| jq-rayforce | janet-query tree, rayforce backend | `route-jq.janet` |

The recorded comparison also ran pandas 3.1.1 (pyarrow 26.0.1), polars 2.1.0,
R 4.5.0 with dplyr 1.2.1 and data.table 1.18.6.1, python 3.13.5; those
routes are not part of this package. Versions recorded by the shipped
routes: janet 1.42.1, janet-duckdb v1.5.6 (DuckDB 1.5.6), janet-rayforce
engine 3.0.1.

## Phases

- **COLD**: no data resident in the route process. Each rep reads the file
  and executes the query; the timer covers read plus execution plus the
  route's native result materialisation.
- **WARM**: the data is loaded once, untimed, into the route's native form,
  then one untimed execution follows, then five timed executions of the
  query only. The native forms are: an in-memory table for duckdb-sql, a
  table on the backend connection for jq-duckdb, a borrowed table handle for
  jq-rayforce.
- The two phases are reported separately and never combined.
- Every invocation is a fresh process. The runner performs one discarded
  invocation per route per phase before the measured pass.
- Timing: `os/clock` (monotonic) in Janet. Reported value is the minimum of
  five reps.

## Queries

All orderings are total: each ORDER BY carries a unique tie-break column.

### q1 - filter and project

```sql
SELECT invoiceid, total FROM read_parquet(?)
WHERE total > 20.0 ORDER BY invoiceid ASC LIMIT 50
```

```janet
(-> (jq/from-parquet P)
    (jq/where (jq/gt (jq/get :total) (jq/lit 20.0)))
    (jq/select :invoiceid :total)
    (jq/order [:invoiceid :asc])
    (jq/limit 50))
```

### q2 - group and aggregate, top N

```sql
SELECT customerid, SUM(total) AS sum_total FROM read_parquet(?)
GROUP BY customerid ORDER BY sum_total DESC, customerid ASC LIMIT 10
```

```janet
(-> (jq/from-parquet P)
    (jq/group [:customerid] (jq/sum (jq/get :total)))
    (jq/order [:sum_total :desc] [:customerid :asc])
    (jq/limit 10))
```

### q3 - join and aggregate

```sql
SELECT i.reports_to, COUNT(i.invoiceid) AS count_invoiceid
FROM read_parquet(?) i
JOIN (SELECT DISTINCT employeeid FROM read_parquet(?)) m
  ON i.reports_to = m.employeeid
GROUP BY i.reports_to ORDER BY i.reports_to ASC
```

```janet
(-> (jq/join (jq/select (jq/from-parquet P) :invoiceid :reports_to)
             (jq/distinct (jq/select (jq/from-parquet P) :employeeid))
             [:reports_to] [:employeeid])
    (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
    (jq/order [:reports_to :asc]))
```

The join sides are projected to numeric columns first: a side carrying a
VARCHAR column is outside the rayforce join surface.

### q4 - top row per group

```sql
WITH latest AS (
  SELECT customerid, MAX(invoicedate) AS max_invoicedate
  FROM read_parquet(?) GROUP BY customerid)
SELECT i.invoicedate, i.invoiceid FROM read_parquet(?) i
JOIN latest ON i.customerid = latest.customerid
  AND i.invoicedate = latest.max_invoicedate
ORDER BY i.invoiceid ASC
```

```janet
(-> (jq/join (jq/select (jq/from-parquet P) :customerid :invoicedate :invoiceid)
             (-> (jq/from-parquet P)
                 (jq/group [:customerid] (jq/max (jq/get :invoicedate))))
             [:customerid :invoicedate] [:customerid :max_invoicedate])
    (jq/select :invoicedate :invoiceid)
    (jq/order [:invoiceid :asc]))
```

This is the window substitute: the v1 node set has no window operator. The
logical plan is identical on every route: group to the maximum key, join
back, order.

### q5 - full-scan aggregate

```sql
SELECT employeeid, COUNT(invoiceid) AS count_invoiceid, SUM(total) AS sum_total,
       AVG(total) AS avg_total
FROM read_parquet(?) GROUP BY employeeid ORDER BY employeeid ASC
```

```janet
(-> (jq/from-parquet P)
    (jq/group [:employeeid]
              (jq/count (jq/get :invoiceid))
              (jq/sum (jq/get :total))
              (jq/avg (jq/get :total)))
    (jq/order [:employeeid :asc]))
```

A keyless `group` (no grouping key) is a duckdb lane only: the rayforce
backend denies it with `:rayforce-no-keys-group`, recorded in the capability
matrix. This query keeps one low-cardinality key so all routes run the same
shape; it still reads every row.

## Fairness and correctness

- One input file for every route, read by each route's native parquet path.
  No route generates its own data.
- The output-equivalence gate runs before any timing is reported: every
  route's canonical row text is compared with the raw-SQL route, per query,
  per phase. The runner exits 1 on any mismatch and prints the first
  differing row. Canonical form: ordered rows, integers as integers, doubles
  at six decimal places.
- Minimum of five reps after a discarded invocation, at each phase.
- Ratios are computed within one run, against the fastest route in that run.
- Two full runs are recorded; the per-cell run-to-run band is reported with
  the tables. Measured band across the 70 recorded cells: 0.53x to 1.27x.
  Expect cells under 3 ms to move most (timer resolution) and the rayforce
  lane to stay inside 10 percent.
- The janet-query duckdb route adds tree expansion and rendering to the raw
  SQL cost; that cost is the measured difference between the duckdb-sql and
  jq-duckdb columns.
- The janet-query rayforce lane spends 800 to 2300 ms per execution on a
  loaded table: the parquet read is 29 ms for this file and a graph build is
  0.2 ms, so the cost sits in the binding's per-execution query path at this
  scale, not in file IO.

## Reproduction

From this directory (the repository root carries the `jennystats/` modules;
`runner.janet` also needs the `jennystats/kit` module on the path - janet-kit
provides it):

```sh
janet gen-data.janet
JANET_PATH="..:$HOME/.local/lib/janet" janet runner.janet 5
```

The machine used for the recorded tables: x86_64, 4 vCPU, Intel Core
Processor (Haswell, no TSX, IBRS), Linux, 2026-11-07.
