# The Chinook fixture

A deterministic, Chinook-shaped dataset for the jennystats/query suite. The
column shapes follow the published Chinook schema by Lucas N. Goncalves (MIT
licence); every row is generated from a fixed seed, so a rerun produces
byte-identical output. Nothing here is hand-authored data.

## Files

- `gen.janet`: writes `schema.sql`, the full ten-table dataset as DDL and
  `INSERT` statements. The rows are defined in `tables.janet`; gen.janet is
  the sink. Seed 20261020; a 32-bit linear congruential generator keyed by it
  drives every sampled value.
- `tables.janet`: the row source. Defines the tables in Janet and writes
  nothing; a rerun of it cannot change any output.
- `schema.sql`: the generated schema script. Loaded by duckdb only; the
  duckdb catalog side and the raw-SQL oracles read it.
- `export.janet`: loads `schema.sql` into a scratch duckdb file and writes
  `chinook.parquet`, the projection both engines load as the same bytes.
- `SHA256SUMS`: the recorded digest of `chinook.parquet`. The suite re-verifies
  it before the first query; a regenerated-different fixture is a hard fail,
  never a silent rebaseline.

## Regeneration

Run from this directory, in this order:

```
janet gen.janet
JANET_PATH=../.. janet export.janet
sha256sum chinook.parquet > SHA256SUMS
```

Both scripts write in the current directory. `gen.janet` imports `./tables`
relative to itself, so it runs with a bare `janet`; `export.janet` imports
`jennystats/typed`, so `JANET_PATH` must name a tree carrying the
`jennystats/` modules (the repository root, `../..` from here, does).
`export.janet` takes an optional
directory argument to redirect a scratch run.

The build artifacts (`.build.duckdb`, `.duckdb.log`) are scratch files and
are ignored by git.

## The export pins

The rayforce parquet reader is the binding constraint. Each pin below was
confirmed by loading the result on both engines, not assumed:

- integer columns are cast to `BIGINT`, because the reader decodes `I64` only
  and defers `I32`;
- decimal columns are cast to `DOUBLE`, because the reader accepts flat
  primitive columns only;
- `COMPRESSION uncompressed` with `DICTIONARY_SIZE_LIMIT 0` forces `PLAIN`
  page encoding, because the reader rejects dictionary pages;
- the export is null-free with no empty strings, because the reader rejects
  null-bearing columns and decodes an empty string as nil, a silent divergence
  from duckdb. Nullable display strings are coalesced to a placeholder before
  the export;
- timestamps become epoch seconds (`I64`), the dated-key interchange shape.

The controlled null set never enters the export. It is injected in memory per
backend (see the lane below), where the null semantics of each engine are the
subject under test.

## What the export carries, and what it cannot serve

The export carries one projection, one row per invoice: `invoiceid`,
`customerid`, `invoicedate` (epoch seconds), `total`, `country`, and the
customer's support representative chain (`employeeid`, `reports_to`,
`lastname`). That is the shape the classic query set groups on. Every other
table is catalogue-side only: it lives in `schema.sql`, read by duckdb and by
the raw-SQL expressions the suite oracles run.

The employee columns ride on the invoice row through the customer's support
representative. That is what makes the reporting chain a self-join over the
shared bytes rather than a catalogue-side query. The chain's top employee has
a NULL `reports_to`, which the reader cannot carry; the export writes the
sentinel `0` instead. A manager with `employeeid` 0 matches nothing, so the
top of the chain is excluded by the join exactly as a NULL key would exclude
it. The sentinel preserves the semantics rather than inventing a row.

The limits that follow from the pins above:

- a query that needs a NULL to arrive from the shared bytes cannot be served
  by this fixture, by construction. The reporting chain's NULL is the one
  case the sentinel above covers, and only because its meaning is
  "matches no manager".

## The in-memory NULL lane

The controlled null set never enters the export. It is built per backend by
the suite from values written in the suite itself: a rayforce dataset through
the engine's own column model, and a duckdb table on the backend connection.
Both see the same rows, NULLs included, which is what makes the two-valued
versus three-valued filter divergence assertable rather than assertable only
in theory.

"The suite" above means the whole test tree: the lane lives in the
rayforce smoke, not the chinook suite. The cells are `diverge-where` and
`where|null-two-valued`, both in test/smoke-query-rayforce.janet.
