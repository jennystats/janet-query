# jennystats/query-duckdb.janet  -  the duckdb backend for jennystats/query.
#
# Part of janet-query (backend module). License: AGPLv3 (see LICENSE).
# The README carries the backend contract: the renderer requirements, the
# result shape and the error-class asymmetry for this backend.
#
# A translator, not a dialect: node tree -> SQL text (HoneySQL school:
# dialect-aware quoting, one node -> one clause, whitespace-stable
# output) -> janet-duckdb's published ffi path (module 0.1.3 -
# UNCHANGED by this file; no engine release rides on it. 0.1.3
# adds the bind-side inferred-type fallback for parameters duckdb reports
# as :unknown, which is what lets a parameterised from-parquet path sit
# beside other parameters).
#
# Binding rules (probe-verified):
#   - every literal in the tree is a bound parameter with an explicit
#     cast (?::BIGINT etc) - duckdb binds reject uncast NaN/inf lanes
#     (parameterised literals ALWAYS emit casts);
#   - LIMIT/OFFSET/where-literals/read_parquet paths are parameters;
#   - COPY TO takes a literal filename (the parser rejects ?:: there) -
#     the path is single-quote-escaped, never a data literal;
#   - tail-limit on an unordered inner renders as a row_number()
#     QUALIFY clause (verified); on an ordered inner as the
#     reverse-limit-reorder composition;
#   - anti-join renders as NOT EXISTS (no ANTI JOIN syntax on 1.5.6).
#
# Connection: backend-owned, LAZY-OPENED in-memory db+conn (the
# renderer's connection,
# held open across prepare/render/execute; (conn) exposes it for
# SQL DDL - from-node binding 2 tables live for the connection's
# lifetime, P10). A user-supplied :conn is a v1.1 additive extension,
# not v1.
#
# Public API: (conn) the backend connection; the registration rides on
# import (jennystats/query register-backend! :duckdb).

(import jennystats/typed :prefix "")
(import jennystats/query :prefix "jq/")
(import jennystats/duckdb :as duckdb)

#==------------------------------------------------------------------------==#
# The backend-owned connection (lazy, in-memory, never closed by the
# module - process lifetime)
#==------------------------------------------------------------------------==#

(var conn* nil)
(var db* nil)

(defn/typed conn {:args [] :ret :struct}
  []
  "The backend's connection: opened on first call (in-memory db);
  held open for the process lifetime. Run SQL DDL for catalog-named
# tables on it directly through janet-duckdb - a from-node :table
# binds the table on THIS connection (lifetime = the connection)."
  (unless conn*
    (set db* (duckdb/open ":memory:"))
    (set conn* (duckdb/connect db*)))
  conn*)

#==------------------------------------------------------------------------==#
# Quoting and literal casts
#==------------------------------------------------------------------------==#

(defn/typed q-ident {:args [:any] :ret :string} [name]
  "DuckDB identifier quoting: double quotes, embedded quotes doubled.
Refuses any non-keyword/non-string identifier: `(string x)` on a
collection yields an opaque address, which must never reach the engine
(contract 4.3 :malformed-tree {:why :select-col-type})."
  (unless (or (keyword? name) (string? name))
    (jq/err :malformed-tree {:why :select-col-type :node name}))
  (string "\"" (string/replace-all "\"" "\"\"" (string name)) "\""))

(defn/typed q-str-lit {:args [:string] :ret :string} [path]
  "Single-quote-escaped SQL string literal (COPY TO filenames only -
  the parser rejects a parameter there; every data literal is a bound
  parameter instead)."
  (string "'" (string/replace-all "'" "''" path) "'"))

(defn/typed lit-cast {:args [:any] :ret :string} [v]
  "The explicit cast every parameterised literal emits, chosen
from the janet value's type. Plain numbers (integral or not) ride
the DOUBLE cast: duckdb leaves an integer-typed parameter's bind
type unknown when it unifies with a DOUBLE column (probed:
pay < ?::BIGINT / pay + ?::INTEGER both fail at bind; ?::DOUBLE
works against integer AND double columns) - and janet numbers are
doubles anyway. Exact beyond-2^53 integers ride the wrapper lanes."
  (cond
    (string? v) "VARCHAR"
    (boolean? v) "BOOLEAN"
    (nil? v) "DOUBLE"
    (= :core/s64 (type v)) "BIGINT"
    (= :core/u64 (type v)) "UBIGINT"
    (number? v) "DOUBLE"
    (jq/err :malformed-tree {:node {:lit v} :why :unsupported-literal})))

#==------------------------------------------------------------------------==#
# Expression rendering
#==------------------------------------------------------------------------==#

(def agg-sql
  "Aggregate op -> SQL function name."
  {:sum "SUM" :avg "AVG" :count "COUNT" :count-distinct "COUNT"
   :min "MIN" :max "MAX" :first "FIRST" :last "LAST"
   :stddev "STDDEV" :var "VARIANCE" :median "MEDIAN"})

(defn/typed in-elems {:args [:any :any] :ret :string}
  [vals st]
  "The membership set fragment: every raw value a bound parameter with
its cast, comma-joined."
  (string/join
    (map (fn [v]
           (def val (if (and (struct? v) (= :lit (get v :expr))) (get v :value) v))
           (array/push (get st :params) val)
           (string "?::" (lit-cast val)))
         vals)
    ", "))

(defn/typed render-expr {:args [:any :any] :ret :string}
  [e st]
  "Expression node -> SQL fragment (recursive); literals push bound
parameters with their cast into the render state."
  (cond
    (= :escape (get e :node)) (get e :text)
    (= :lit (get e :expr))
    (do (array/push (get st :params) (get e :value))
        (string "?::" (lit-cast (get e :value))))
    (= :get (get e :expr))
    (if (get e :alias)
      (string (q-ident (get e :alias)) "." (q-ident (get e :col)))
      (q-ident (get e :col)))
    (= :agg (get e :expr))
    (let [fn (or (get agg-sql (get e :agg))
                 (jq/err :malformed-tree {:node e :why :unknown-agg}))]
      (cond
        # count is the shared ROW-COUNT aggregate: rayforce counts
        # rows, duckdb COUNT(col) counted
        # non-nulls - the lane settled on row-count semantics, so the
        # renderer emits COUNT(*) regardless of the column argument; the
        # arg is not rendered, so no phantom parameter is pushed)
        (= :count (get e :agg)) "COUNT(*)"
        (= :count-distinct (get e :agg))
        (string "COUNT(DISTINCT " (render-expr (get e :arg) st) ")")
        (string fn "(" (render-expr (get e :arg) st) ")")))
    (= :call (get e :expr))
    (let [op (get e :op)
          args (get e :args)
          a0 (render-expr (args 0) st)]
      (case op
        :add (string "(" a0 " + " (render-expr (args 1) st) ")")
        :sub (string "(" a0 " - " (render-expr (args 1) st) ")")
        :mul (string "(" a0 " * " (render-expr (args 1) st) ")")
        :div (string "(" a0 " / " (render-expr (args 1) st) ")")
        :idiv
        # truncated integer division (the duckdb lane: rayforce floors - a
        # documented per-backend divergence). CAST double->int ROUNDS in
        # duckdb (probed: CAST(3/2.0) = 2), so TRUNC carries the
        # truncate-toward-zero semantics; the operands are doubles
        # under the literal-cast rule
        (string "(TRUNC((" a0 " / " (render-expr (args 1) st) ")))")
        :mod (string "(" a0 " % " (render-expr (args 1) st) ")")
        :eq (string "(" a0 " = " (render-expr (args 1) st) ")")
        :ne (string "(" a0 " <> " (render-expr (args 1) st) ")")
        :lt (string "(" a0 " < " (render-expr (args 1) st) ")")
        :le (string "(" a0 " <= " (render-expr (args 1) st) ")")
        :gt (string "(" a0 " > " (render-expr (args 1) st) ")")
        :ge (string "(" a0 " >= " (render-expr (args 1) st) ")")
        :and (string "(" a0 " AND " (render-expr (args 1) st) ")")
        :or (string "(" a0 " OR " (render-expr (args 1) st) ")")
        :not (string "(NOT " a0 ")")
        :isnull (string "(" a0 " IS NULL)")
        :min2 (string "LEAST(" a0 ", " (render-expr (args 1) st) ")")
        :max2 (string "GREATEST(" a0 ", " (render-expr (args 1) st) ")")
        :if (string "(CASE WHEN " a0 " THEN " (render-expr (args 1) st)
                    " ELSE " (render-expr (args 2) st) " END)")
        :in
        (let [elems (in-elems (tuple/slice args 1) st)]
          (string "(" a0 " IN (" elems "))"))
        :not-in
        (let [elems (in-elems (tuple/slice args 1) st)]
          (string "(" a0 " NOT IN (" elems "))"))
        (jq/err :malformed-tree {:node e :why :unknown-call-op})))
    (jq/err :malformed-tree {:node e :why :not-an-expression})))

# the aggregate output-name convention lives in the core (jq/expr-name,
# shared by both backends - slice 3)

(defn/typed render-col {:args [:any :any] :ret :string}
  [c st]
  "A select/group key column: keyword -> quoted name, expression ->
rendered fragment."
  (if (struct? c) (render-expr c st) (q-ident c)))

#==------------------------------------------------------------------------==#
# The tree renderer (one node -> one clause; nesting at every
# non-source boundary keeps composition semantics exact and the
# output whitespace-stable)
#==------------------------------------------------------------------------==#

# render and sub are mutually recursive - janet has no forward
# references (definitions precede use), so both land as vars
(var render nil)
(var sub nil)
(var join-from nil)

(defn/typed zip-keys {:args [:any :any] :ret :array}
  [lks rks]
  "[lkeys rkeys] -> [[lk rk] ...] position-aligned pairs (no zip in
core 1.42.1)."
  (seq [i :range [0 (min (length lks) (length rks))]] [(lks i) (rks i)]))

(set sub (fn [tree st]
  # render tree as a parenthesised derived table with its stable alias
  # slot: (SELECT ...) AS "qN"
  (def alias (string "q" (get st :n)))
  (put st :n (inc (get st :n)))
  (string "(" (render tree st) ") AS " (q-ident alias))))

(set join-from (fn [tree st]
  # the join's FROM fragment (sides, aliases, ON / NOT EXISTS); shared
  # by the :join node (SELECT * <frag>) and the fused select/where
  # over a join (qualified refs cannot cross a derived-table boundary,
  # so the projection/filter composes INTO the join scope)
  (def jt (get tree :type))
  # side aliases follow the from-nodes' :alias when present (P14:
  # column qualification follows the alias); generated qN otherwise
  (def la (or (and (struct? (get tree :left)) (get (get tree :left) :alias))
              (string "q" (get st :n))))
  # one alias slot per side, deterministic numbering whether the alias
  # is the from-node's :alias or generated
  (put st :n (inc (get st :n)))
  (def ra (or (and (struct? (get tree :right)) (get (get tree :right) :alias))
              (string "q" (get st :n))))
  (put st :n (inc (get st :n)))
  (def pairs (zip-keys (get tree :lkeys) (get tree :rkeys)))
  (def on-eq
    (string/join
      (map (fn [[lk rk]] (string (q-ident la) "." (q-ident lk)
                                 " = " (q-ident ra) "." (q-ident rk)))
           pairs)
      " AND "))
  (if (= :anti jt)
    (string "FROM (" (render (get tree :left) st) ") AS " (q-ident la)
            " WHERE NOT EXISTS (SELECT 1 FROM (" (render (get tree :right) st)
            ") AS " (q-ident ra) " WHERE " on-eq ")")
    (let [join-kw (case jt :inner "JOIN" :left "LEFT JOIN" :full "FULL JOIN"
                    :asof "ASOF JOIN"
                    (jq/err :malformed-tree {:node tree :why :join-type}))
          # asof: first key pair is the time inequality, the rest eq keys
          on-clause
          (if (= :asof jt)
            (let [asof-key (string (q-ident la) "." (q-ident ((get tree :lkeys) 0))
                                   " <= " (q-ident ra) "."
                                   (q-ident ((get tree :rkeys) 0)))
                  eq-rest (zip-keys (tuple/slice (get tree :lkeys) 1)
                                    (tuple/slice (get tree :rkeys) 1))
                  on-eq-rest
                  (string/join
                    (map (fn [[lk rk]] (string (q-ident la) "." (q-ident lk)
                                               " = " (q-ident ra) "." (q-ident rk)))
                         eq-rest)
                    " AND ")]
              (if (empty? on-eq-rest) asof-key
                (string asof-key " AND " on-eq-rest)))
            (if (empty? on-eq) "TRUE" on-eq))]
      (string "FROM (" (render (get tree :left) st) ") AS " (q-ident la)
              " " join-kw
              " (" (render (get tree :right) st) ") AS " (q-ident ra)
              " ON " on-clause)))))

(set render (fn [tree st]
  (def n (get tree :node))
  (case n
    :from
    (let [src (get tree :src)]
      (when (or (struct? src) (table? src))
        # (v1) duckdb binds parquet paths and catalog-named SQL tables only
        # - a handle source is not renderable here
        (jq/err :malformed-tree {:node tree :why :duckdb-handle-source}))
      (string "SELECT * FROM " (q-ident src)
              (if (get tree :alias) (string " AS " (q-ident (get tree :alias))) "")))
    :from-parquet
    (do (array/push (get st :params) (get tree :path))
        (string "SELECT * FROM read_parquet(?::VARCHAR)"
                (if (get tree :alias) (string " AS " (q-ident (get tree :alias))) "")))
    :where
    (let [inner (get tree :input)]
      # fusion: a filter directly over a join predicates INTO the join
      # scope (qualified refs cannot cross a derived-table boundary)
      (if (and (struct? inner) (= :join (get inner :node)))
        (string "SELECT * " (join-from inner st)
                " WHERE " (render-expr (get tree :pred) st))
        (string "SELECT * FROM " (sub inner st)
                " WHERE " (render-expr (get tree :pred) st))))
    :group
    (let [keys (get tree :keys)
          aggs (get tree :aggs)
          key-frag (string/join (map |(render-col $0 st) keys) ", ")
          agg-frag (string/join
                     (map (fn [a]
                            (string (render-expr a st) " AS "
                                    (q-ident (jq/expr-name a))))
                          aggs)
                     (if (empty? aggs) "" ", "))
          proj (if (empty? aggs)
                (if (empty? keys) "*" key-frag)
                (if (empty? keys) agg-frag (string key-frag ", " agg-frag)))]
      (string "SELECT " proj " FROM " (sub (get tree :input) st)
              " GROUP BY "
              (if (empty? keys) "ALL" key-frag)))
    :select
    (let [inner (get tree :input)
          proj (if (empty? (get tree :cols))
                 "*"
                 (string/join (map |(render-col $0 st) (get tree :cols)) ", "))]
      # fusion: a projection directly over a join composes INTO the
      # join scope (same boundary rule as where-over-join)
      (if (and (struct? inner) (= :join (get inner :node)))
        (string "SELECT " proj " " (join-from inner st))
        (string "SELECT " proj " FROM " (sub inner st))))
    :order
    (string "SELECT * FROM " (sub (get tree :input) st)
            " ORDER BY "
            (string/join
              (map (fn [k]
                     (string (q-ident (get k :col))
                             (if (= :desc (get k :dir)) " DESC" " ASC")))
                   (get tree :keys))
              ", "))
    :limit
    (let [inner (get tree :input)]
      (if (= :tail (get tree :form))
        (if (and (struct? inner) (= :order (get inner :node)))
          # ordered tail: reverse, limit, re-order (verified lane);
          # the LIMIT param trails the sub's params in the text
          (let [keys (get inner :keys)
                fwd (string/join
                      (map (fn [k] (string (q-ident (get k :col))
                                           (if (= :desc (get k :dir)) " DESC" " ASC")))
                           keys)
                      ", ")
                rev (string/join
                      (map (fn [k] (string (q-ident (get k :col))
                                           (if (= :desc (get k :dir)) " ASC" " DESC")))
                           keys)
                      ", ")
                inner-sql (string "SELECT * FROM " (sub (get inner :input) st)
                                  " ORDER BY " rev " LIMIT ?::BIGINT")]
            (array/push (get st :params) (get tree :n))
            (string "SELECT * FROM (" inner-sql ") AS "
                    (q-ident (string "q" (get st :n)))
                    " ORDER BY " fwd))
          # unordered tail: engine-order last-n via row_number QUALIFY
          # (verified); the param trails the sub's params in the text
          (let [base (string "SELECT * FROM " (sub inner st)
                             " QUALIFY row_number() OVER ()"
                             " >= (count(*) OVER () - ?::BIGINT + 1)")]
            (array/push (get st :params) (get tree :n))
            base))
        # head: the param trails the sub's params in the text
        (let [base (string "SELECT * FROM " (sub inner st) " LIMIT ?::BIGINT")]
          (array/push (get st :params) (get tree :n))
          base)))
    :distinct
    (string "SELECT DISTINCT * FROM " (sub (get tree :input) st))
    :append
    (string/join
      (map |(string "SELECT * FROM " (sub $0 st)) (get tree :sides))
      " UNION ALL ")
    :join
    (string "SELECT * " (join-from tree st))
    :write-parquet
    (string "COPY (" (render (get tree :input) st) ") TO "
            (q-str-lit (get tree :path)) " (FORMAT PARQUET)")
    (jq/err :malformed-tree {:node tree :why :unknown-node}))))

(defn/typed render-form {:args [:any] :ret :table}
  [tree]
  "Node tree -> the duckdb engine form @{:sql :params :backend :kind}:
the SQL text (whitespace-stable, snapshot-testable), the positional
parameter vector in traversal order, and the node kind (the
write-parquet result lane). The tree is the table-name source - no
SQL parsing anywhere in this module."
  (def st @{:params @[] :n 0})
  (def form @{:sql (render tree st) :params (get st :params) :backend :duckdb})
  (when (and (struct? tree) (= :write-parquet (get tree :node)))
    (put form :kind :write-parquet))
  form)

#==------------------------------------------------------------------------==#
# Execution (through janet-duckdb's published path, contract v1.4)
#==------------------------------------------------------------------------==#

(defn/typed exec-form {:args [:any] :ret :table}
  [form]
  "Engine form -> the one result wrapper @{:rows @[...] :columns [...]}
via prepared statement + positional binds on the backend connection.
NULL maps to nil both directions, NaN stays NaN-distinct (duckdb
contract v1.4); values beyond the double-safe band survive as
int/s64-int/u64 wrappers per the module's typed lanes. write-parquet
returns the rows-changed count as a one-row result."
  (def c (conn))
  (with [stmt (duckdb/prepare c (get form :sql))]
    (with [result (duckdb/execute stmt (tuple ;(get form :params)))]
      (if (= :write-parquet (get form :kind))
        (jq/wrap-result @[@[(duckdb/rows-changed result)]] @[:rows-changed])
        (let [rows (duckdb/rows result false :tuple)]
          (jq/wrap-result @[;rows]
                          @[;(map keyword (get result :column-names))]))))))

#==------------------------------------------------------------------------==#
# Registration (contract 4.1) + the coverage manifest rows
#==------------------------------------------------------------------------==#

(def duckdb-matrix
  "The v1 duckdb compatibility matrix: the
shared set, where/join/asof as extensions (where
three-valued, anti native), escape (:duckdb tag), count-distinct
NATIVE (COUNT(DISTINCT)), median, the per-backend
expression lanes (idiv truncating, in/not-in). window/pivot/wco
are NOT declared - denied by every v1 backend."
  {:from :shared :group :shared :select :shared :order :shared
   :limit :shared :distinct :shared :from-parquet :shared
   :append :native :write-parquet :native
   :where :native :join :native :join-anti :native :asof :native
   :escape :native
   :count-distinct :native :median :native
   :expr-idiv :native :expr-mod :native :expr-in :native :expr-not-in :native})

(jq/register-backend!
  @{:name :duckdb
    :renderer render-form
    :execute exec-form
    :catalog-spec @{}
    :matrix duckdb-matrix})

(jq/add-manifest! :duckdb
  {"from|base" "s2-p11-from"
   "group|base" "s2-p11-group"
   "group|null-agg" "s2-p11-group-null"
   "select|base" "s2-p11-select"
   "order|base" "s2-p11-order"
   "limit|base" "s2-p11-limit"
   "limit|tail" "s2-p11-limit-tail"
   # the module smoke's tail already exercises the ids below; the rows make
   # the matrix promise traceable (slice 4's completeness gate reads them)
   "expr-in|base" "s2-p11-in"
   "distinct|base" "s2-p11-distinct"
   "distinct|null" "s2-p11-distinct-null"
   "append|base" "s2-p11-append"
   "from-parquet|base" "s2-p11-parquet"
   "write-parquet|base" "s2-p11-parquet-write"
   "where|base" "s2-p11-where"
   "where|null" "s2-p12-null-where"
   "join|base" "s2-p11-join"
   "join|null-key" "s2-p11-join-nullkey"
   "join|anti" "s2-p11-anti"
   "asof|base" "s2-p11-asof"
   "count-distinct|base" "s2-p11-count-distinct"
   "count-distinct|null" "s2-p11-count-distinct-null"
   "median|base" "s2-p11-median"
   "expr-idiv|base" "s2-p11-idiv"
   "expr-mod|base" "s2-p11-mod"
   "expr-in|base" "s2-p11-in"
   "lit|nan" "s2-p12-nan"
   "lit|null" "s2-p12-null"
   "lit|nul-string" "s2-p12-nul-string"
   "lit|u64-beyond-2^53" "s2-p12-u64"
   "lit|wrong-type" "s2-p12-wrong-type"
   "escape|base" "s2-p11-escape"
   "conn|lifecycle" "s2-conn-lifecycle"})
