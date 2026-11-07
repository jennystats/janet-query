# Janet-query examples

Every example is a Janet program that builds a query tree and executes it on
one or both engines. Each one was run and its output is the text below.

The examples read the Chinook parquet fixture shipped in this repository.
Set `CHINOOK` to its path (from the `examples/` directory):

```sh
export CHINOOK=../test/fixtures/chinook/chinook.parquet
```

Run an example with `janet`, with the repository root on the module path so
the `jennystats` modules resolve:

```sh
JANET_PATH=.. janet basic-select-filter.janet
```

The examples import `jennystats/query`
and the two backend modules, which register when imported.

Engine support below is the documented matrix, verified by running each example.

## 1. Basic select, filter, order, limit

`jennystats/query` builds inert trees. `execute` takes the tree and one
backend; there is no default backend.

```janet
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def q (-> (jq/from-parquet P)
           (jq/where (jq/gt (jq/get :total) (jq/lit 300.0)))
           (jq/select :invoiceid :total)
           (jq/order [:total :desc] [:invoiceid :asc])
           (jq/limit 5)))

(each backend [:duckdb :rayforce]
  (def res (jq/execute q :backend backend))
  (printf "%s columns=%q" backend (get res :columns))
  (each row (get res :rows) (printf "  %q" row)))
```

Output (file `basic-select-filter.janet`):

```
duckdb columns=@[:invoiceid :total]
  (373 400.99)
  (901 400.99)
  (1061 400.99)
  (1397 400.99)
  (1413 400.99)
rayforce columns=@[:invoiceid :total]
  (373 400.99)
  (901 400.99)
  (1061 400.99)
  (1397 400.99)
  (1413 400.99)
```

`where` is a per-backend extension. The two engines agree on null-free data;
their null semantics differ, and the contract records both.

## 2. Composition

Nodes stack in reading order. `distinct` is part of the shared set.

```janet
(def q (-> (jq/from-parquet P)
           (jq/select :customerid)
           (jq/distinct)
           (jq/order [:customerid :asc])
           (jq/limit 5)))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
```

Output (`composition.janet`):

```
duckdb @[(1) (2) (3) (4) (5)]
rayforce @[(1) (2) (3) (4) (5)]
```

A `distinct` fed by a VARCHAR projection is outside the rayforce surface: the
backend raises the malformed-tree class with `:why :rayforce-str-boundary`
rather than returning a partial result.

## 3. Joins

`join` is a per-backend extension. On the rayforce lane a join side must be
projected to its numeric columns; a side carrying a VARCHAR column raises
`:rayforce-str-join-rename`. The join and anti variants are declared per
backend: both engines serve inner, left and full here; anti is a duckdb lane.

```janet
(def invoices (jq/select (jq/from-parquet P) :invoiceid :reports_to))
(def managers (jq/distinct (jq/select (jq/from-parquet P) :employeeid)))

(def q (-> (jq/join invoices managers [:reports_to] [:employeeid] :left)
           (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
           (jq/order [:reports_to :asc])))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
```

Output (`joins.janet`):

```
duckdb @[(2 1980)]
rayforce @[(2 1980)]
```

The Chinook export gives every invoice row the same manager sentinel, so a
left join is the variant that keeps rows in this data set.

## 4. Group and aggregate

The shared aggregate set is sum, avg, count, min, max, first, last, stddev
and var. `count-distinct` and `median` are duckdb extensions and are refused
on the rayforce lane with `:extension-denied`.

```janet
(def q (-> (jq/from-parquet P)
           (jq/group [:customerid] (jq/sum (jq/get :total)))
           (jq/order [:sum_total :desc] [:customerid :asc])
           (jq/limit 3)))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
```

Output (`group-aggregate.janet`):

```
duckdb @[(8 8047.66999999999) (9 7896.67) (54 7865.66999999999)]
rayforce @[(8 8047.66999999999) (9 7896.67) (54 7865.66999999999)]
```

The aggregate output name is the operator and the column joined by an
underscore, so `(jq/sum (jq/get :total))` produces `sum_total`.

## 5. Loading: parquet, and what happens to a CSV path

`from-parquet` is shared. It binds a parquet path. A CSV path is not a source
the query surface knows: the path is handed to the parquet reader and fails
there on both engines.

```janet
(def parquet-q (jq/limit (jq/select (jq/from-parquet P) :invoiceid) 3))
(each backend [:duckdb :rayforce]
  (printf "%s parquet %q" backend (get (jq/execute parquet-q :backend backend) :rows)))

(def csv-q (jq/limit (jq/select (jq/from-parquet "chinook.csv") :invoiceid) 3))
(each backend [:duckdb :rayforce]
  (printf "%s csv %s" backend
          (try (string "served " (get (jq/execute csv-q :backend backend) :rows))
               ([e] (string "refused: " e)))))
```

Output (`loading-parquet-csv.janet`):

```
duckdb parquet @[(1) (2) (3)]
rayforce parquet @[(1) (2) (3)]
duckdb csv refused: duckdb: IO Error: No files found that match the pattern "chinook.csv"

LINE 1: SELECT * FROM (SELECT "invoiceid" FROM (SELECT * FROM read_parquet(?::VARCHAR)) AS "q1") AS "q0" LIMIT ?::BIGINT
                                                              ^
rayforce csv refused: rayforce: parquet open failed: io: parquet: cannot map chinook.csv
```

Convert CSV to parquet before the query when the data starts as CSV. The
query surface reads one format on purpose, and both engines read the same
bytes.

## 6. Catalogued sources

A catalogue entry describes a source's columns. With a catalogue, a name the
description does not carry is refused at the tree pass, on both engines,
before the engine is called.

```janet
(def catalog {P {:columns [:invoiceid :customerid :invoicedate :total
                           :country :employeeid :reports_to :lastname]
                 :writer P}})

(def known-q (jq/limit (jq/select (jq/from-parquet P) :invoiceid :total) 2))
(def unknown-q (jq/select (jq/from-parquet P) :region))

(each backend [:duckdb :rayforce]
  (printf "%s known %q" backend
          (get (jq/execute known-q :backend backend :catalog catalog) :rows))
  (printf "%s unknown %s" backend
          (try (string (get (jq/execute unknown-q :backend backend :catalog catalog) :rows))
               ([e] (string "refused: " (string/format "%q" e))))))
```

Output (`catalogued-sources.janet`):

```
duckdb known @[(1 332.99) (2 367.99)]
duckdb unknown refused: {:error :unknown-column :name :region}
rayforce known @[(1 332.99) (2 367.99)]
rayforce unknown refused: {:error :unknown-column :name :region}
```

## 7. Errors

Three refusal classes: an unknown node, an operator a backend does not
declare, and a tree whose sides carry two engines' handles.

```janet
(def src (jq/from-parquet P))

(printf "unknown node: %s"
        (try (jq/execute {:node :pivot :input src} :backend :duckdb)
             ([e] (string/format "%q" e))))

(def cd (jq/group src [:customerid] (jq/count-distinct (jq/get :invoicedate))))
(printf "count-distinct on rayforce: %s"
        (try (jq/execute cd :backend :rayforce) ([e] (string/format "%q" e))))

(def mixed (jq/join (jq/from @{:backend :duckdb :handle 1})
                    (jq/from @{:backend :rayforce :handle 2}) :k :k))
(printf "mixed handles: %s"
        (try (jq/execute mixed :backend :duckdb) ([e] (string/format "%q" e))))
```

Output (`errors.janet`):

```
unknown node: {:backend :duckdb :error :extension-denied :operator :pivot}
count-distinct on rayforce: {:backend :rayforce :error :extension-denied :operator :count-distinct}
mixed handles: {:backends (:duckdb :rayforce) :error :malformed-tree :node {:node :from :src @{:backend :rayforce :handle 2}} :why :cross-backend-handles}
```

Errors are values, not strings to parse: `:error` names the class and the
payload names the node, the operator or the backends involved.

## 8. Catalogue admission

When a catalogue entry names a different writer, the described set still
serves a plain read of its listed columns. A name outside the description is
refused at the where lane. This is the admission rule the contract certifies
for entries whose writer is another source.

```janet
(def catalog {P {:columns [:invoiceid :total] :writer "another.parquet"}})
(def src (jq/from-parquet P))

(printf "plain select columns: %q"
        (get (jq/expand-tree (jq/select src :total) catalog) :columns))
(printf "plain select execute: %q"
        (get (jq/execute (jq/limit (jq/select src :total) 2) :backend :duckdb
                         :catalog catalog) :rows))
(printf "where on an unlisted column: %s"
        (try (jq/expand-tree (jq/where src (jq/gt (jq/get :zzz) (jq/lit 1))) catalog)
             ([e] (string/format "%q" e))))
```

Output (`admission.janet`):

```
plain select columns: (:total)
plain select execute: @[(332.99) (367.99)]
where on an unlisted column: {:error :unknown-column :name :zzz}
```

## 9. Raw SQL and a query tree side by side

The same query twice. Raw SQL through the duckdb binding is the shorter
route for a one-off. The tree is the form that also runs on the other
engine, carries the catalogue contract and refuses unknown names before the
engine is called.

```janet
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/duckdb :as dd)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

# raw SQL through the duckdb binding
(def db (dd/open ""))
(def conn (dd/connect db))
(def sql (string "SELECT customerid, SUM(total) AS sum_total "
                 "FROM read_parquet(?) GROUP BY customerid "
                 "ORDER BY sum_total DESC, customerid ASC LIMIT 3"))
(def raw (with [r (dd/query conn sql [P])] (dd/rows r false :tuple)))
(:close conn)
(:close db)

# the same query as a tree
(def tree (-> (jq/from-parquet P)
              (jq/group [:customerid] (jq/sum (jq/get :total)))
              (jq/order [:sum_total :desc] [:customerid :asc])
              (jq/limit 3)))
(def rows (get (jq/execute tree :backend :duckdb) :rows))

(printf "raw SQL: %q" raw)
(printf "tree:    %q" rows)
(printf "identical: %v" (deep= (map |(tuple ;$) raw) rows))
```

Output (`raw-sql-vs-tree.janet`):

```
raw SQL: @[(8 8047.66999999999) (9 7896.67) (54 7865.66999999999)]
tree:    @[(8 8047.66999999999) (9 7896.67) (54 7865.66999999999)]
identical: true
```

The tree costs a rendering step. The cross-language benchmark measures that
cost next to the raw SQL and the other engines.
