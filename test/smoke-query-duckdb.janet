# smoke-query-duckdb - the duckdb backend conformance smoke: render
# coverage (every shared operator renders executable SQL against a
# hand-computed expected value) and the parameter-binding edges. Requires
# libduckdb (SKIP if absent - present-but-broken is a FAIL, never a skip).
#
# Cell ids name the coverage-manifest rows seeded in query-duckdb.janet
# (operator x edge-class).
(import jennystats/query :prefix "jq/")
(import jennystats/query-duckdb :as jqd)
(import jennystats/duckdb :as duckdb)

(defn assert-eq [a b msg]
  (unless (deep= a b) (errorf "FAIL %s: %q != %q" msg a b)))

(defn catch-err [f]
  (var c nil)
  (try (f) ([e] (set c e)))
  c)

(defn- err-is? [e want]
  (and (struct? e) (struct? want)
       (all (fn [[k v]] (deep= (get e k) v)) (pairs want))))

(defn assert-errz [f want msg]
  (assert-eq (err-is? (catch-err f) want) true msg))

(defn ex [q] (jq/execute q :backend :duckdb))
(defn rn [q] (jq/render q :backend :duckdb))

# -- fixture: SQL DDL on the backend's own connection (from-node binding 2) --
(def c (jqd/conn))
(duckdb/exec c `CREATE TABLE emp (id INTEGER, dept VARCHAR, pay DOUBLE)`)
(duckdb/exec c `INSERT INTO emp VALUES
                 (1, 'a', 1.5), (2, 'a', 2.5), (3, NULL, 3.5), (4, 'b', 4.5)`)
(duckdb/exec c `CREATE TABLE dept (dept VARCHAR, floor INTEGER)`)
(duckdb/exec c `INSERT INTO dept VALUES ('a', 7), ('b', 8)`)

# -- s2-conn: the ratified lazy-open connection model ----------------------
# The DDL above ran on the first call's connection (first-use open, an
# in-memory db); every later call returns the same handle and the tables
# stay visible - one connection, process lifetime, never closed by the
# module.
(assert-eq (type (jqd/conn)) :struct "s2-conn-lifecycle|handle is a struct")
(assert (deep= (jqd/conn) c)
        "s2-conn-lifecycle|conn reuse: the same handle across calls")
(var emp-count nil)
(with [r (duckdb/query (jqd/conn) "SELECT count(*) AS n FROM emp")]
  (set emp-count ((first (duckdb/rows r false :tuple)) 0)))
(assert-eq emp-count 4
           "s2-conn-lifecycle|tables created on first use live on the conn")

# -- every shared operator, hand-computed expected ----------------------

# s2-p11-from: implicit projection = source column order
(assert-eq (ex (jq/from :emp))
           @{:columns @[:id :dept :pay]
             :rows @[[1 "a" 1.5] [2 "a" 2.5] [3 nil 3.5] [4 "b" 4.5]]}
           "s2-p11-from|base (source column order)")

# s2-p11-select
(assert-eq (ex (jq/select (jq/from :emp) :id :pay))
           @{:columns @[:id :pay]
             :rows @[[1 1.5] [2 2.5] [3 3.5] [4 4.5]]}
           "s2-p11-select|base (projection order)")

# s2-p11-where (duckdb extension, three-valued)
(assert-eq (ex (jq/where (jq/from :emp) (jq/lt (jq/get :pay) (jq/lit 3))))
           @{:columns @[:id :dept :pay]
             :rows @[[1 "a" 1.5] [2 "a" 2.5]]}
           "s2-p11-where|base")
# NULL lane: SQL three-valued drops unknown rows
(assert-eq (ex (jq/where (jq/from :emp) (jq/isnull (jq/get :dept))))
           @{:columns @[:id :dept :pay] :rows @[[3 nil 3.5]]}
           "s2-p11-where|null (unknown drops the row; isnull named)")

# s2-p11-group: sum + NULL lane (NULL pay in a group excluded from SUM)
(assert-eq (ex (jq/order (jq/select (jq/group (jq/from :emp) [:dept]
                                              (jq/sum (jq/get :pay)))
                                    :dept :sum_pay)
                          [:dept :asc]))
           @{:columns @[:dept :sum_pay]
             :rows @[["a" 4] ["b" 4.5] [nil 3.5]]}
           "s2-p11-group|base (sum per key; ASC NULLS LAST duckdb default)")
(assert-eq (ex (jq/order (jq/select (jq/group (jq/from :emp) [:dept])
                                       :dept)
                         [:dept :asc]))
           @{:columns @[:dept] :rows @[["a"] ["b"] [nil]]}
           "group|null-key (NULL is a key value; unordered group is
order-insensitive, ordered here for a stable comparison)")
(assert-eq (ex (jq/order (jq/select (jq/group (jq/from :emp) [:dept]
                                              (jq/count (jq/get :dept)))
                                    :dept :count_dept)
                          [:dept :asc]))
           @{:columns @[:dept :count_dept]
             :rows @[["a" 2] ["b" 1] [nil 1]]}
           "group|null-agg (count is the shared ROW-COUNT aggregate:
COUNT(*) per key - COUNT(col) would skip NULLs; the cell expects [nil 0])")

# s2-p11-order + s2-p11-limit (head and tail, ordered)
(assert-eq (ex (jq/limit (jq/order (jq/from :emp) [:id :desc]) 2))
           @{:columns @[:id :dept :pay] :rows @[[4 "b" 4.5] [3 nil 3.5]]}
           "s2-p11-limit|head-over-ordered")
(assert-eq (ex (jq/limit (jq/order (jq/from :emp) [:id :asc]) 2 :tail))
           @{:columns @[:id :dept :pay] :rows @[[3 nil 3.5] [4 "b" 4.5]]}
           "s2-p11-limit|tail-over-ordered (reverse-limit-reorder)")

# s2-p11-distinct incl NULL
(assert-eq (ex (jq/order (jq/distinct (jq/select (jq/from :emp) :dept)) [:dept :asc]))
           @{:columns @[:dept] :rows @[["a"] ["b"] [nil]]}
           "s2-p11-distinct|base+null (NULL distinct once)")

# s2-p11-append: UNION ALL, position-aligned
(assert-eq (ex (jq/limit (jq/append (jq/select (jq/from :emp) :id)
                                   (jq/select (jq/from :emp) :id)) 8))
           @{:columns @[:id]
             :rows @[[1] [2] [3] [4] [1] [2] [3] [4]]}
           "s2-p11-append|base (UNION ALL, 8 rows)")

# s2-p11-join: inner + alias self-join (P14 lane) + NULL key (never matches)
(assert-eq (ex (jq/order (jq/select (jq/join (jq/from :emp :alias :e)
                                            (jq/from :dept :alias :d)
                                            [:dept] [:dept] :inner)
                                 (jq/get :id :e) (jq/get :dept :e) (jq/get :floor :d))
                         [:id :asc]))
           @{:columns @[:id :dept :floor]
             :rows @[[1 "a" 7] [2 "a" 7] [4 "b" 8]]}
           "s2-p11-join|base+alias (NULL-key row 3 dropped: SQL never matches null keys)")
(assert-eq (ex (jq/order (jq/select (jq/join (jq/from :emp :alias :e)
                                            (jq/from :dept :alias :d)
                                            [:dept] [:dept] :left)
                                 (jq/get :id :e) (jq/get :floor :d))
                         [:id :asc]))
           @{:columns @[:id :floor]
             :rows @[[1 7] [2 7] [3 nil] [4 8]]}
           "s2-p11-join|left (null key keeps the left row)")

# s2-p11-anti (duckdb extension): employees whose dept has no floor row
(assert-eq (ex (jq/order (jq/select (jq/join (jq/from :emp :alias :e)
                                            (jq/from :dept :alias :d)
                                            [:dept] [:dept] :anti)
                                 (jq/get :id :e))
                         [:id :asc]))
           @{:columns @[:id] :rows @[[3]]}
           "s2-p11-anti|base (only the NULL-dept row)")

# s2-p11-asof (duckdb extension, P8-verified native): asof self-join
(duckdb/exec c `CREATE TABLE ts (id INTEGER, t INTEGER, v DOUBLE)`)
(duckdb/exec c `INSERT INTO ts VALUES (1, 10, 1.0), (1, 20, 2.0), (2, 15, 3.0)`)
(assert-eq (ex (jq/order (jq/select (jq/join (jq/from :ts :alias :l)
                                            (jq/from :ts :alias :r)
                                            [:t :id] [:t :id] :asof)
                                 (jq/get :id :l) (jq/get :t :l) (jq/get :v :r))
                         [:id :asc] [:t :asc]))
           @{:columns @[:id :t :v] :rows @[[1 10 1.0] [1 20 2.0] [2 15 3.0]]}
           "s2-p11-asof|base (latest r.t <= l.t with id partition; total key)")

# s2-p11-count-distinct (duckdb native) + NULL lane
(assert-eq (ex (jq/select (jq/group (jq/from :emp) []
                                    (jq/count-distinct (jq/get :dept)))
                          :count-distinct_dept))
           @{:columns @[:count-distinct_dept] :rows @[[2]]}
           "s2-p11-count-distinct|null (COUNT(DISTINCT) skips NULLs: a,b of 3)")

# s2-p11-median (duckdb extension)
(assert-eq (ex (jq/select (jq/group (jq/from :emp) []
                                    (jq/median (jq/get :pay)))
                          :median_pay))
           @{:columns @[:median_pay] :rows @[[3]]}
           "s2-p11-median|base (cont quantile of 1.5,2.5,3.5,4.5)")

# expression lanes: idiv (truncating), mod, in
(assert-eq (ex (jq/where (jq/from :emp) (jq/eq (jq/idiv (jq/get :id) (jq/lit 2))
                                               (jq/lit 1))))
           @{:columns @[:id :dept :pay] :rows @[[2 "a" 2.5] [3 nil 3.5]]}
           "s2-p11-idiv|base (truncated integer division: 3//2=1)")
(assert-eq (ex (jq/where (jq/from :emp) (jq/eq (jq/mod (jq/get :id) (jq/lit 2))
                                               (jq/lit 1))))
           @{:columns @[:id :dept :pay] :rows @[[1 "a" 1.5] [3 nil 3.5]]}
           "s2-p11-mod|base")
(assert-eq (ex (jq/where (jq/from :emp) (jq/in (jq/get :id) [1 4])))
           @{:columns @[:id :dept :pay] :rows @[[1 "a" 1.5] [4 "b" 4.5]]}
           "s2-p11-in|base (bound set)")

# -- m1-3: the renderer refuses a non-identifier rather than quoting an address
# (a nested projection is refused at the tree pass; a hand-built node bypasses
# composition, so the renderer is the last fence)
(assert-errz (fn [] (rn {:node :select :cols @[(tuple :x)] :input {:node :from :src :emp}}))
  {:error :malformed-tree :why :select-col-type}
  "m1-3/render|non-identifier-col-refused-by-the-renderer")

# s2-p11-parquet: write then read the SAME bytes back (shared-shape I/O)
(assert-eq (ex (jq/write-parquet (jq/order (jq/select (jq/from :emp) :id :pay)
                                           [:id :asc])
                                 "/tmp/jq-smoke.parquet"))
           @{:columns @[:rows-changed] :rows @[(tuple 4)]}
           "s2-p11-parquet|write (rows changed)")
(assert-eq (ex (jq/from-parquet "/tmp/jq-smoke.parquet"))
           @{:columns @[:id :pay] :rows @[[1 1.5] [2 2.5] [3 3.5] [4 4.5]]}
           "s2-p11-parquet|read round-trip")

# s2-p11-escape: verbatim fragment at a defined position (expression atom)
(assert-eq (ex (jq/where (jq/from :emp)
                         (jq/and2 (jq/escape :duckdb "\"id\" >= 2")
                                   (jq/lit true))))
           @{:columns @[:id :dept :pay] :rows @[[2 "a" 2.5] [3 nil 3.5] [4 "b" 4.5]]}
           "s2-p11-escape|base (SQL fragment verbatim)")

# -- render snapshots: whitespace-stable, one node -> one clause --------------
(assert-eq ((rn (jq/from :emp)) :sql)
           "SELECT * FROM \"emp\""
           "s2-snapshot|from")
(assert-eq ((rn (jq/where (jq/from :emp) (jq/lt (jq/get :pay) (jq/lit 3)))) :sql)
           "SELECT * FROM (SELECT * FROM \"emp\") AS \"q0\" WHERE (\"pay\" < ?::DOUBLE)"
           "snapshot|where (cast param)")
(assert-eq ((rn (jq/where (jq/from :emp) (jq/lt (jq/get :pay) (jq/lit 3)))) :params)
           @[3]
           "s2-snapshot|where params (literal is data, never text)")
(assert-eq ((rn (jq/select (jq/group (jq/from :emp) [:dept] (jq/sum (jq/get :pay)))
                          :dept :sum_pay)) :sql)
           (string "SELECT \"dept\", \"sum_pay\" FROM"
                   " (SELECT \"dept\", SUM(\"pay\") AS \"sum_pay\""
                   " FROM (SELECT * FROM \"emp\") AS \"q1\""
                   " GROUP BY \"dept\") AS \"q0\"")
           "s2-snapshot|group+select (deterministic nesting and agg names)")
(assert-eq ((rn (jq/limit (jq/order (jq/from :emp) [:id :desc]) 2)) :sql)
           (string "SELECT * FROM (SELECT * FROM (SELECT * FROM \"emp\")"
                   " AS \"q1\" ORDER BY \"id\" DESC) AS \"q0\""
                   " LIMIT ?::BIGINT")
           "s2-snapshot|order+limit")
(assert-eq ((rn (jq/write-parquet (jq/from :emp) "/tmp/o'brien.parquet")) :sql)
           "COPY (SELECT * FROM \"emp\") TO '/tmp/o''brien.parquet' (FORMAT PARQUET)"
           "s2-snapshot|write-parquet (path literal, quotes escaped)")
(assert-eq ((rn (jq/from-parquet "/tmp/f.parquet" :alias :p)) :sql)
           "SELECT * FROM read_parquet(?::VARCHAR) AS \"p\""
           "s2-snapshot|from-parquet (path is a bound parameter)")

# -- parameter-binding edges (from trees) ----

# NaN: payload passes through NaN-distinct (duckdb contract v1.4)
(def nan-row (ex (jq/select (jq/from :emp) (jq/lit math/nan))))
(assert (nan? (((get nan-row :rows) 0) 0)) "s2-p12-nan|value passes NaN-distinct")

# NULL literal: binds NULL
(def null-row (ex (jq/select (jq/from :emp) (jq/lit nil))))
(assert-eq (length (get null-row :columns)) 1
           "s2-p12-null|one derived column")
(assert-eq (get null-row :rows) @[[nil] [nil] [nil] [nil]]
           "s2-p12-null|binds NULL (per-row projection)")
(assert (string/find "DOUBLE" (string ((get null-row :columns) 0)))
        "s2-p12-null|derived name carries the cast")

# NUL-bearing string: the module's clean raise (varchar boundary)
(def nul-err (catch-err (fn [] (ex (jq/select (jq/from :emp) (jq/lit "a\000b"))))))
(unless (and nul-err (string/find "embedded NUL" (string nul-err)))
  (errorf "FAIL s2-p12-nul-string: %q" nul-err))

# u64 beyond 2^53: wrapper lane binds exact, reads back as wrapper
(def u64-row (ex (jq/select (jq/from :emp) (jq/lit (int/u64 "18446744073709551615")))))
(assert-eq (((get u64-row :rows) 0) 0) (int/u64 "18446744073709551615")
           "s2-p12-u64|beyond-2^53 exact round-trip")

# wrong-typed literal: db error AT EXECUTE (the parser decides)
(def wt-err (catch-err (fn [] (ex (jq/where (jq/from :emp)
                                            (jq/add (jq/get :dept) (jq/lit 1)))))))
(unless (and wt-err (string/find "duckdb" (string wt-err)))
  (errorf "FAIL s2-p12-wrong-type (db error at execute): %q" wt-err))

# NaN where-lane: NaN compares NaN=NaN TRUE on duckdb (documented, R7
# excluded from equivalence; recorded, not hidden)
(assert-eq (ex (jq/where (jq/from :emp) (jq/eq (jq/lit math/nan)
                                               (jq/lit math/nan))))
           @{:columns @[:id :dept :pay]
             :rows @[[1 "a" 1.5] [2 "a" 2.5] [3 nil 3.5] [4 "b" 4.5]]}
           "s2-p12-nan|where-eq-true (duckdb NaN lane, documented)")

# NaN parity half: the duckdb renderer keeps the NaN literal as a bound
# parameter - the rayforce renderer normalises it to NULL (its f64 lane
# has no second meaning for NaN). Asserted as a divergence
# pair, never as equivalence.
(def nan-lit-form (rn (jq/select (jq/from :emp) (jq/lit math/nan))))
(assert-eq (length (get nan-lit-form :params)) 1
           "s2-cr3b|duckdb render keeps the NaN literal as a bound parameter")
(assert (nan? ((get nan-lit-form :params) 0))
        "s2-cr3b|the bound parameter IS NaN (no render-side normalisation)")

# -- the coverage manifest rows are committed data ----------------------------
(assert (jq/coverage-manifest :duckdb) "s2-manifest|duckdb rows present")
(assert (get (jq/coverage-manifest :duckdb) "from|base")
        "s2-manifest|op|edge keys")

# -- 8.2.4: janet-duckdb unchanged - everything above ran through the
# published module's open/connect/prepare/execute path on the backend's
# own conn; no duckdb release rides on this module (recorded in the
# outcome, verified by the direct calls above)

(print "RESULT: pass")
