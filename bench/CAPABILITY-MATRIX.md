# Capability matrix

Measured, not assumed. The driver is `capability-matrix.janet` against the
Chinook fixture (1,980 rows, the same bytes the query suite uses); the raw
output is `results/capability-matrix.out` (41 cells, all pass). The rows
below are the node classification and the documented exclusions, measured.

| feature | duckdb lane | rayforce lane | notes |
|---|---|---|---|
| parquet source | serves | serves | shared `from-parquet` |
| CSV source | refused | refused | a from-node binds a parquet path; the contract has no CSV reader, so a `.csv` path goes to the parquet reader and fails there |
| select and project | serves | serves | shared |
| where | serves | serves | per-backend; equal on null-free data, null semantics differ (documented divergence) |
| order, limit | serves | serves | shared |
| distinct | serves | serves | shared on numeric keys; a distinct fed by a VARCHAR projection raises `:rayforce-str-boundary` |
| join inner, left, full | serves | serves | per-backend; sides must be projected to numeric columns on rayforce (`:rayforce-str-join-rename` otherwise); null-key matching differs (documented divergence) |
| join anti | serves | denied | `:extension-denied :operator :join-anti` |
| group aggregates sum, avg, count, min, max, first, last, stddev, var | serves | serves | shared set |
| count-distinct | serves | denied | `:extension-denied :operator :count-distinct` |
| median | serves | denied | `:extension-denied :operator :median` |
| group with no keys | serves | denied | `:malformed-tree :why :rayforce-no-keys-group` |
| append | serves | denied | `:extension-denied :operator :append` |
| write-parquet | serves | denied | `:extension-denied :operator :write-parquet` |
| group on a VARCHAR key | serves | serves | the group itself works; feeding its VARCHAR result into a further node raises `:rayforce-str-boundary` |
| cross-backend handles | denied | denied | `:malformed-tree :why :cross-backend-handles`, both backends listed |
| catalogued source, known column | serves | serves | caller catalogue honoured on render and execute |
| catalogued source, unknown column | refused | refused | `{:error :unknown-column :name :zzz}` |
| catalogue admission | serves and refuses as documented | serves and refuses as documented | a plain read serves the entry's listed columns; a where on an unlisted name raises `:unknown-column` |
| parquet rows per file | no limit measured | 65,536 | 65,536 rows decode; 65,537 raises `column total: expected number or nil, got array` |

## Recorded gaps (documented text, measured as recorded)

- Non-sequence `:columns`: a string or keyword iterates as bytes and
  describes a byte list; an integer raises the raw host error. Recorded
  limitation, unchanged.
- Order keys remain outside the name check.
- Group keys are name-checked at expansion (a recorded limitation of the
  contract text; the engine is stricter than the text).
- The exclusions register (union order, empty `:columns`, from-source arms,
  the two-record same-path lane, append width, writers beyond two records) is
  outside the model and not licensed; each item is verified as documented.

## Window-shaped work

The v1 node set has no window operator. The `:window` node is denied by
every registered backend; duckdb serves window frames through the escape
hatch only. The benchmark's q4 uses the group-and-join substitute so the
same logical plan runs on both lanes.
