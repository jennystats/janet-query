# jennystats/query-rayforce.janet  -  the rayforce backend for jennystats/query.
#
# Part of janet-query (backend module). License: AGPLv3 (see LICENSE).
# The README carries the backend contract: the renderer requirements, the
# result shape and the error-class asymmetry (engine-detected misuse raises
# the module's typed errors at execute).
#
# A TRANSLATOR, not a dialect: node tree -> janet-rayforce's published
# DAG surface (module 0.1.5 or later, engine v3.0.2 - the engine is
# UNCHANGED by this file; no engine release rides on it). Everything
# module-unbound is a named gap the matrix DENIES - never a silent
# substitute.
#
# The staged model (the module's own shape, probe-verified):
#   - ray_group / ray_distinct take NO input op - they run over the
#     graph's BOUND table only. A prefix chain before them executes
#     engine-side where the payload is all-numeric (the result table is
#     aliased to the contract column names - engine agg outputs are named
#     col_agg, the contract names are agg_col), then they run over the
#     aliased table in a fresh graph; a payload carrying any other column
#     type decodes and re-ingests janet-side first.
#   - filter/select/sort/head/tail compose engine-side in one graph:
#     their column arguments resolve BY NAME against the input table
#     (probe-verified: select/sort after filter project the filtered
#     rows), and a filter's mask must match the INPUT row count
#     (probe-verified engine raise: "WHERE mask length N does not
#     match row count M").
#   - consecutive where nodes merge into ONE filter (and-composition,
#     the algebraic identity over the segment source); a where after
#     any row-reducing op (applied filter, limit, join) first
#     materialises - a second mask over the reduced rows would
#     misalign (the named refusal lane).
#   - Fresh-graph rule: a FRESH graph per segment execution; no graph, op or
#     table is reused across execute calls. Group keys are
#     column ops only (a table-node key folds to a length-1 answer
#     engine-side - never emitted). The in-memory F64 join zero-row
#     observation did not reproduce (correct 2-row result, twice) -
#     fixture artifact, not a module behaviour.
#
# The two alignment fences (the blocking scope, enforced before any
# engine call): every column reference in a where predicate (fence 1,
# :filter-pred-row-scope) and in a group key/agg input (fence 2,
# :group-agg-row-scope) must resolve against the current output scope -
# a reference outside it raises the malformed-tree class BEFORE any
# engine call. (The raw module's misaligned group agg is SILENTLY
# wrong, probe-verified: a 2-row agg column over 3 groups returned
# @[0 0 1], exit 0 - the engine folds the short column; the module
# does not fence it. The misaligned filter pred DOES raise engine-side,
# at execute, after plan-build - the backend fence moves it to
# translation, in the contract class.)
#
# Ownership: every graph, intermediate table and result the backend
# creates is closed on its path (net 0 per translate-execute-decode cycle,
# measured under ray_mem_trace); user-supplied
# table handles are borrowed, never closed. STR decode copies values into
# janet strings (the empty-text -> nil divergence is documented).
# Re-ingest after a segment boundary is numeric-only (the module's
# deferred STR fence): a boundary whose payload carries STR columns and
# is followed by more chain raises :rayforce-str-boundary naming the
# node. Terminal groups decode STR keys/aggs directly (count/first/last/
# min/max are type-agnostic). Boundary crossings, join sides and group
# results run ENGINE-SIDE where the payload is all-numeric: the executed
# table is aliased to its contract names (rf/-table-alias) instead of
# being decoded and re-ingested, so the values never leave the engine.
# A group result with a numeric payload is handed back as a SEGMENT for
# that reason, so a following order/limit composes engine-side over the
# aliased table (the high-cardinality top-K shape: an n-group result is
# sorted and cut in the engine and only the terminal rows are decoded).
# The decode path still runs for any non-numeric column type, and that
# is where the STR/SYM fences live.
#
# v1 from-node binding set: a parquet path (from-parquet: flat
# null-free PLAIN I64/F64/STR; multi-batch files merge engine-side
# through the binding's batch concat, every reader type carried), an
# in-janet dataset (src @{:backend :rayforce :columns @[@[name col]
# ...]} ordered pairs, or a struct plus an :order array), or a module
# table handle (src @{:backend :rayforce :handle tbl}; column order is
# not publicly readable through the module - sorted names, documented,
# unless a select defines the order). Catalog-named SQL tables are NOT
# bindable on rayforce (no named-table registry in the module surface).
#
# Documented divergences (matrix notes): where is two-valued
# (nulls compare as negative infinity - a null row is KEPT by lt/le/ne
# at any threshold, probe-verified); join keys match null-to-null
# (null-matching keys); idiv/mod floor; order puts nulls first on desc
# keys (matching the duckdb DESC NULLS FIRST convention; ASC nulls-last
# on both engines); implicit (from-only) projection surfaces columns in
# sorted-name order (an explicit select defines the order); NaN decodes
# as nil (the unified mapping).
#
# Public API: the registration rides on import (jennystats/query
# register-backend! :rayforce).
(import jennystats/typed :prefix "")
(import jennystats/query :prefix "jq/")
(import jennystats/rayforce :as rf)

#==------------------------------------------------------------------------==#
# Source resolution (the v1 binding set)
#==------------------------------------------------------------------------==#

(defn/typed resolve-dataset {:args [:any] :ret :tuple}
  [src]
  "In-janet dataset :columns -> ordered [name column-array] pairs:
ordered pairs, a struct plus an :order array, or a bare struct (sorted
order)."
  (def cols (get src :columns))
  (cond
    (indexed? cols)
    (do (each p cols
         (unless (and (indexed? p) (= 2 (length p)) (string? (p 0)))
           (jq/err :malformed-tree
                   {:why :rayforce-dataset-shape :node src :backend :rayforce})))
        (tuple ;(map (fn [p] [(p 0) (p 1)]) cols)))
    (or (struct? cols) (table? cols))
    (let [order (get src :order)]
      (if order
        (do (each k order
              (unless (get cols k)
                (jq/err :malformed-tree
                        {:why :rayforce-dataset-order :node src
                         :name k :backend :rayforce})))
            (tuple ;(map (fn [k] [(string k) (get cols k)]) order)))
        (tuple ;(map (fn [k] [(string k) (get cols k)])
                    (sorted (keys cols))))))
    (jq/err :malformed-tree
            {:why :rayforce-dataset-shape :node src :backend :rayforce})))

(defn/typed -names-of {:args [:any] :ret :array}
  [tbl]
  "Column names only: no row decode (the fast name path). Sorted, the
 documented implicit-projection order - column order is not recoverable
 through the public surface."
  (sorted (seq [i :range [0 (rf/table-ncols tbl)]] (rf/-column-name tbl i))))

(defn/typed source-table {:args [:any] :ret :table}
  [tree]
  "A from/from-parquet node -> @{:tbl handle :cols [names] :owned bool}.
from-parquet: parquet-rows (single batch owned direct; multi-batch
merged engine-side by the binding's batch concat, so I64, F64 and STR
columns all cross the batch boundary without a janet decode). from: an
in-janet dataset or a borrowed module table handle; a name source
(catalog table) is NOT bindable."
  (def n (get tree :node))
  (cond
    (= n :from-parquet)
    (let [batches (rf/parquet-rows (get tree :path))]
      (when (empty? batches)
        (jq/err :malformed-tree
                {:why :rayforce-empty-parquet :node tree :backend :rayforce}))
      (if (= 1 (length batches))
        @{:tbl (batches 0) :owned true
          :cols (-names-of (batches 0))}
        (do
          (defer (each b batches (:close b))
            @{:tbl (rf/-concat-batches batches)
              :owned true :cols (-names-of (batches 0))}))))

    (= n :from)
    (let [src (get tree :src)]
      (cond
        (and (or (struct? src) (table? src)) (= :rayforce (get src :backend)))
        (if (get src :handle)
          @{:tbl (get src :handle) :owned false
            :cols (-names-of (get src :handle))}
          (let [pairs (resolve-dataset src)]
            @{:tbl (rf/table-from-columns
                     (table ;(mapcat (fn [p] [(p 0) (p 1)]) pairs)))
               :owned true :cols (tuple ;(map first pairs))}))
        (or (keyword? src) (string? src))
        (jq/err :malformed-tree
                {:why :rayforce-unbindable-source :node tree :name src
                 :backend :rayforce})
        (jq/err :malformed-tree
                {:why :rayforce-unbindable-source :node tree
                 :backend :rayforce})))
    (jq/err :malformed-tree
            {:why :rayforce-source :node tree :backend :rayforce})))

#==------------------------------------------------------------------------==#
# Segment state (live graph) and result state (decoded)
#==------------------------------------------------------------------------==#

# SEGMENT fields: :g :tbl (the source handle) :cols (source col names)
# :out (current output col names) :op (current table-op, nil = source)
# :pred (pending merged predicate op) :applied (rows reduced: a filter
# folded or a limit/join applied) :owned (backend owns :tbl) :side-map
# ({alias {col name}} post-join) :close-right/:right-tbl (the join's
# added table, owned)
#
# RESULT fields: :res (owned result table handle) :cols (decoded
# column arrays, tracked order) :out (output names). Group/distinct
# produce it; the terminal decode reads it directly (no re-ingest -
# STR keys decode to the wrapper), a following node converts it to a
# fresh SEGMENT first (numeric-only, the STR boundary).

(defn/typed new-segment {:args [:any :any :any] :ret :table}
  [tbl cols owned]
  "A fresh segment over tbl: its graph, column scope and ownership flag."
  @{:kind :segment :tbl tbl :cols cols :out cols :scan-scope cols
    :decode-names cols
    :g (rf/graph tbl)
    :op nil :pred nil :applied false :owned owned :side-map @{}})

(defn/typed close-segment {:args [:any] :ret :nil}
  [s]
  "Close a segment's graph and, when backend-owned, its source table.
The state is dead afterwards."
  (when (get s :g) (:close (get s :g)))
  (when (get s :right-tbl) (when (get s :close-right)
                             (:close (get s :right-tbl))))
  (when (and (get s :owned) (get s :tbl)) (:close (get s :tbl)))
  nil)

(defn/typed close-result {:args [:any] :ret :nil}
  [r]
  "Close a result's engine table, if it carries one."
  (when (get r :res) (:close (get r :res)))
  nil)

#==------------------------------------------------------------------------==#
# Expression translation + the two alignment fences
#==------------------------------------------------------------------------==#

(defn/typed scan-for {:args [:any :any] :ret :struct}
  [s ref]
  "The scan op for a resolved fence entry @{:name :col-tid} - plain scan
for the bound table's columns, scan-table for a renamed copy (col-tid) or
a join-added side's column (the join segment tracks its added table id)."
  (def nm (get ref :name))
  (cond
    (get ref :col-tid) (rf/scan-table (get s :g) (get ref :col-tid) nm)
    (and (get s :tid) (index-of nm (get s :right-cols)))
    (rf/scan-table (get s :g) (get s :tid) nm)
    (rf/scan (get s :g) nm)))

(defn/typed fence {:args [:any :any :any :keyword :any] :ret :table}
  [s col alias why node]
  "Resolve a column reference against the current output scope - the
 two alignment fences. Fence 1 (:filter-pred-row-scope): a where
predicate column outside the scope. Fence 2 (:group-agg-row-scope): a
group key or agg input outside the scope. Aliased references resolve
through the join side-map (post-join scope); an unqualified reference
over a join resolves through the sides when exactly one side carries
the name (renamed-copy columns are alias-qualified - the duckdb
fuser's plain-name semantics), and raises when ambiguous or absent.
Returns @{:name :col-tid}: col-tid is the added-table id a renamed copy
scans through, nil for a plain bound-graph column. A name carried by no
side but present in the left side's own columns (a collision-free join)
resolves plain. Raises the malformed-tree class BEFORE any engine call."
  (def nm (string col))
  # the side-map value is @{:name :col-tid}; a bare name is a plain
  # column (its name is a STRING, a struct's name is not - the guard tests
  # for the string, not for :name's presence)
  (defn entry [v] (if (and (dictionary? v) (string? (get v :name)))
                    v @{:name v :col-tid nil}))
  (if alias
    (do (def side (get (get s :side-map) (string alias)))
        (unless side
          (jq/err :malformed-tree
                  {:why why :node node :name (string alias)
                   :backend :rayforce}))
        (def out (get side nm))
        (unless out
          (jq/err :malformed-tree
                  {:why why :node node :name nm :backend :rayforce}))
        (entry out))
    (if (index-of nm (get s :scan-scope))
      @{:name nm :col-tid nil}
      (do
        # unqualified over a join: unique-side resolution
        (def hits
          (seq [alias :in (sorted (keys (get s :side-map)))
                :when (get (get (get s :side-map) alias) nm)]
            (get (get (get s :side-map) alias) nm)))
        (if (= 1 (length hits))
          (entry (hits 0))
          # a segment that is not a join carries no :left-cols; the scan
          # scope has already missed, so the reference is absent either way
          (if (and (empty? hits) (index-of nm (get s :left-cols @[])))
            @{:name nm :col-tid nil}
            (jq/err :malformed-tree
                    {:why why :node node :name nm :backend :rayforce})))))))

(defn/typed translate-expr {:args [:any :any] :ret :struct}
  [s e]
  "Expression node -> rayforce op in the segment's source scope (fence
1 for where preds). The shared core; numeric literals const-f64,
booleans const-bool; nil/string literals raise the named boundaries
(no const-str op exists - the string-expression gap; nil composes
through isnull)."
  (def g (get s :g))
  (cond
    (= :escape (get e :node))
    (jq/err :extension-denied {:operator :escape :backend :rayforce})
    (= :lit (get e :expr))
    (let [v (get e :value)]
      (cond
        (number? v) (rf/const-f64 g v)
        (boolean? v) (rf/const-bool g v)
        (jq/err :malformed-tree
                {:why (if (or (string? v) (buffer? v))
                        :rayforce-string-literal :rayforce-nil-literal)
                 :node e :backend :rayforce})))
    (= :get (get e :expr))
    (scan-for s (fence s (get e :col) (get e :alias)
                       :filter-pred-row-scope e))
    (= :agg (get e :expr))
    (jq/err :malformed-tree
            {:why :rayforce-agg-out-of-group :node e :backend :rayforce})
    (= :call (get e :expr))
    (let [args (map |(translate-expr s $0) (get e :args))]
      (case (get e :op)
        :add (rf/add g ;args)
        :sub (rf/sub g ;args)
        :mul (rf/mul g ;args)
        :div (rf/div g ;args)
        :idiv (rf/idiv g ;args)
        :mod (rf/mod g ;args)
        :eq (rf/eq g ;args)
        :ne (rf/ne g ;args)
        :lt (rf/lt g ;args)
        :le (rf/le g ;args)
        :gt (rf/gt g ;args)
        :ge (rf/ge g ;args)
        :and (rf/and2 g ;args)
        :or (rf/or2 g ;args)
        :not (rf/not g ;args)
        :isnull (rf/isnull g ;args)
        :min2 (rf/min2 g ;args)
        :max2 (rf/max2 g ;args)
        :if (rf/if g ;args)
        (jq/err :extension-denied
                {:operator :expr :backend :rayforce :why (get e :op)})))
    (jq/err :malformed-tree
            {:why :rayforce-expression :node e :backend :rayforce})))

#==------------------------------------------------------------------------==#
# Materialisation (execute + decode + re-ingest, contract names)
#==------------------------------------------------------------------------==#

(defn/typed decode-ordered {:args [:any :any] :ret :array}
  [tbl names]
  "A result table's columns by tracked order (values through the
decode path: numbers, nil, STR strings copied out; NaN decodes as
nil, the unified mapping)."
  (def cols (rf/table-columns tbl))
  (map (fn [nm] (get cols nm)) names))

(defn/typed ingest {:args [:any :any] :ret :any}
  [names col-arrays]
  "Decoded columns -> a fresh backend-owned table with ordered names
(numeric-only; the module's deferred STR fence raises on a STR
payload)."
  (rf/table-from-columns
    (table ;(mapcat (fn [i] [(names i) (if (array? (col-arrays i))
                                         (col-arrays i)
                                         @[;(col-arrays i)])])
                    (range (length names))))))

# exception: returns a derived value, raises the backend class; a
# return guard would mask it
(defn str-boundary
  "Raise the STR boundary for a non-numeric payload node."
  [node]
  (jq/err :malformed-tree
          {:why :rayforce-str-boundary :node node :backend :rayforce}))

(defn/typed check-numeric-boundary {:args [:any :any] :ret :nil}
  [cols node]
  "A boundary payload carrying STR raises the named boundary."
  (each c cols
    (each v (if (array? c) c @[c])
      (when (or (string? v) (buffer? v)) (str-boundary node)))))

# The zero-copy lanes: I64 (5) and F64 (7) are the two engine types a
# boundary may pass through undecoded. A table whose columns are all
# numeric is aliased by name (zero-copy); any other type takes the decode
# path, where the STR/SYM fences live.
(def NUMERIC-TAGS {5 true 7 true})

(defn/typed -numeric-table? {:args [:any] :ret :boolean} [tbl]
  "True when every column of tbl is an I64/F64 engine vector (no decode)."
  (var ok true)
  (each t (rf/-column-tags tbl)
    (unless (get NUMERIC-TAGS t) (set ok false)))
  ok)

(defn/typed -engine-names {:args [:any] :ret :tuple} [tbl]
  "A table's column names in engine order (names only, no decode)."
  (tuple ;(seq [i :range [0 (rf/table-ncols tbl)]] (rf/-column-name tbl i))))

(defn/typed -rename-map {:args [:any :any] :ret :table} [olds news]
  "old name -> new name, positionally paired (the alias call maps by NAME)."
  (def m @{})
  (for i 0 (min (length olds) (length news))
    (put m (olds i) (news i)))
  m)

# The zero-copy renames (group output, join sides, materialise boundary)
# go through rf/-table-alias, which refuses duplicate OUTPUT names. The
# engine accepts duplicate column names at the naming boundary but its two
# read paths then disagree (table-column resolves the first, table-columns
# keeps the last), so a colliding rename is refused in the module class
# before the alias call rather than read back ambiguously.

(defn/typed -duplicate-name {:args [:any] :ret :any} [names]
  "The first output name that occurs more than once, or nil."
  (var seen @{})
  (var dup nil)
  (each nm names
    (when (nil? dup)
      (if (get seen nm)
        (set dup nm)
        (put seen nm true))))
  dup)

(defn/typed rename-collision {:args [:any :any :any] :ret :nil}
  [olds news node]
  "Raises the malformed-tree class when a positional rename would map two
engine columns onto one output name. Runs before the alias call."
  (when-let [dup (or (-duplicate-name news) (-duplicate-name olds))]
    (jq/err :malformed-tree
            {:why :rayforce-duplicate-output-name :node node
             :name dup :backend :rayforce}))
  nil)

# A rename through rf/-table-alias: the collision fence first, then the
# module's error translation (the alias call raises for a rename map that
# misses a name - a backend-side fault, kept as its own message).
(defn/typed -table-alias {:args [:any :any :any :any] :ret :any}
  [tbl olds news node]
  "Alias tbl to news, positionally over olds. Raises the module class."
  (rename-collision olds news node)
  (try
    (rf/-table-alias tbl (-rename-map olds news))
    ([e] (jq/err :malformed-tree
                 {:why :rayforce-table-alias
                  :detail (if (string? e) e (string/format "%q" e))
                  :node node :backend :rayforce}))))

(defn/typed -col-tag {:args [:any :string] :ret :number} [tbl nm]
  "The engine type tag of the named column in tbl (0 when absent)."
  (var tag 0)
  (def tags (rf/-column-tags tbl))
  (for i 0 (rf/table-ncols tbl)
    (when (= nm (rf/-column-name tbl i)) (set tag (tags i))))
  tag)

(defn/typed root-op {:args [:any] :ret :struct}
  [s]
  "The segment's current root table-op: the pending predicate folded
  over the current op (or the source)."
  (def base (or (get s :op) (rf/const-table (get s :g) (get s :tbl))))
  (if (get s :pred)
    (rf/filter (get s :g) base (get s :pred))
    base))

(defn/typed exec-decode {:args [:any] :ret :tuple}
  [s]
  "Execute the segment root; decode by tracked output order. Closes
  the result on the caller's path via the returned cleanup marker."
  (def res (rf/execute (get s :g) (root-op s)))
  [res (decode-ordered res (get s :decode-names))])

(defn/typed materialize {:args [:any :any] :ret :table}
  [s node]
  "SEGMENT -> fresh SEGMENT over a re-ingested table: executes the
current root, decodes in tracked order, re-ingests (numeric boundary
fence), closes everything owned. The side-map survives (post-join
aliased references stay resolvable after a where-after-join boundary)."
  (def [res cols] (exec-decode s))
  (defer (do (close-segment s) (:close res))
    (check-numeric-boundary cols node)
    (def names (tuple ;(get s :out)))
    (def fresh (new-segment (ingest names cols) names true))
    (put fresh :side-map (get s :side-map))
    fresh))

(defn/typed materialize-engine {:args [:any :any] :ret :table}
  [s node]
  "SEGMENT -> fresh SEGMENT over its EXECUTED result table: the root op
runs and the result is aliased to the tracked names, so the values never
leave the engine (no decode, no re-ingest). An all-numeric result takes
that path; any other column type falls back to the decode step, which is
where the STR boundary and the SYM class live. Closes everything
owned, keeps the side-map."
  (def res (rf/execute (get s :g) (root-op s)))
  (def names (tuple ;(get s :out)))
  (def dnames (tuple ;(get s :decode-names)))
  (if (and (-numeric-table? res) (deep= (-engine-names res) dnames))
    (defer (close-segment s)
      (def t (-table-alias res dnames names node))
      (:close res)
      (def fresh (new-segment t names true))
      (put fresh :side-map (get s :side-map))
      fresh)
    (do
      (def cols (decode-ordered res dnames))
      (defer (do (close-segment s) (:close res))
        (check-numeric-boundary cols node)
        (def fresh (new-segment (ingest names cols) names true))
        (put fresh :side-map (get s :side-map))
        fresh))))

(defn/typed result->segment {:args [:any :any] :ret :table}
  [r node]
  "RESULT -> fresh SEGMENT over the decoded columns (numeric boundary;
  the group/distinct output columns carry the contract names)."
  (defer (close-result r)
    (check-numeric-boundary (get r :cols) node)
    (def names (tuple ;(get r :out)))
    (new-segment (ingest names (get r :cols)) names true)))

#==------------------------------------------------------------------------==#
# The chain translator
#==------------------------------------------------------------------------==#

(def agg-engine-name
  "Aggregate op -> the engine's output-column suffix (probe-verified:
sum/count/min/max/first/last/stddev/var map straight; avg names its
output col_mean - the engine's own naming, decoded positionally and
surfaced under the contract name agg_col)."
  {:sum "sum" :avg "mean" :count "count" :min "min" :max "max"
   :first "first" :last "last" :stddev "stddev" :var "var"})

(defn/typed apply-node {:args [:any :any] :ret :table}
  [s node]
  "One non-join chain node onto a SEGMENT (RESULT states are converted
  by compile-node before this)."
  (case (get node :node)
    :where
    (do
      # a where after a row-reducing op materialises first: a second
      # mask over reduced rows is the filter-misalignment lane
      (def s0 (if (get s :applied) (materialize s node) s))
      (def pred (translate-expr s0 (get node :pred)))
      (put s0 :pred
           (if (get s0 :pred)
             (rf/and2 (get s0 :g) (get s0 :pred) pred)
             pred))
      s0)
    :select
    (let [sel (get node :cols)]
      (if (empty? sel)
        s
        (do
          # the fence resolves each reference to the SCAN name (the
          # join side's output name); the surfaced output name is the
          # user's reference (a plain name stays plain - the duckdb
          # fuser's semantics)
          (defn ref-name [c]
            (if (and (dictionary? c) (= :get (get c :expr)))
              (string (get c :col))
              (string c)))
          (def resolved
            (map (fn [c]
                   (cond
                     (or (keyword? c) (string? c))
                     (fence s c nil :filter-pred-row-scope node)
                     (and (dictionary? c) (= :get (get c :expr)))
                     (fence s (get c :col) (get c :alias)
                            :filter-pred-row-scope node)
                     # expression projections: the per-backend lane
                     # (rayforce select takes column ops only)
                     (jq/err :extension-denied
                             {:operator :select :backend :rayforce
                              :why :expression-projection})))
                 sel))
          (def ops (map (fn [nm] (scan-for s nm)) resolved))
          (def input (root-op s))
          (put s :op (rf/select (get s :g) input ops))
          (when (get s :pred)
            (put s :pred nil)
            (put s :applied true))
          (put s :out (tuple ;(map ref-name sel)))
          (put s :decode-names (tuple ;(map (fn [r] (get r :name)) resolved)))
          s)))
    :order
    (let [keys (get node :keys)
          names (map (fn [k] (fence s (get k :col) nil
                                     :filter-pred-row-scope node)) keys)
          g (get s :g)
          descs (map (fn [k] (= :desc (get k :dir))) keys)]
      (put s :op (rf/sort g (root-op s)
                          (map (fn [nm] (scan-for s nm)) names)
                          descs descs))
      (when (get s :pred)
        (put s :pred nil)
        (put s :applied true))
      s)
    :limit
    (do
      (put s :op (if (= :tail (get node :form))
                   (rf/tail (get s :g) (root-op s) (get node :n))
                   (rf/head (get s :g) (root-op s) (get node :n))))
      (when (get s :pred) (put s :pred nil))
      (put s :applied true)
      s)
    :distinct
    (let [s0 (if (or (get s :applied) (get s :op) (get s :pred))
               (materialize-engine s node)
               s)
          keys (get s0 :out)]
      # distinct runs over the bound table only (no input op) - it is
      # its own segment; the output re-ingests for the post-chain
      (def op (rf/distinct (get s0 :g)
                           (map (fn [nm] (scan-for s0 @{:name nm :col-tid nil}))
                                keys)))
      (def res (rf/execute (get s0 :g) op))
      (defer (close-segment s0)
        (def cols (decode-ordered res keys))
        @{:kind :result :res res :cols cols :out (tuple ;keys)
          :engine-names (tuple ;keys)}))
    :group
    (let [s0 (if (or (get s :applied) (get s :op) (get s :pred))
               (materialize-engine s node)
               s)]
      # the engine's ray_group requires at least one key (probe-verified
      # raise: "group: no keys") - the no-keys global-aggregate shape is
      # a named rayforce gap (duckdb serves GROUP BY ALL); never a
      # silent substitute (a constant-key trick would change semantics)
      (when (empty? (get node :keys))
        (jq/err :malformed-tree
                {:why :rayforce-no-keys-group :node node
                 :backend :rayforce}))
      # fence 2: keys and agg inputs resolve against the group's input
      # scope, before any engine call. Keys are source-named columns;
      # agg inputs are column references (a constant agg input has no
      # scan op - count a non-null column instead)
      (def key-names
        (map (fn [k]
               (if (or (keyword? k) (string? k))
                 (fence s0 k nil :group-agg-row-scope node)
                 (jq/err :malformed-tree
                         {:why :rayforce-group-key-column :node node
                          :backend :rayforce})))
             (get node :keys)))
      # the surfaced key names are the user's references (a plain
      # name stays plain over a join-materialised segment)
      (def key-out
        (map (fn [k]
               (if (and (dictionary? k) (get k :col))
                 (string (get k :col))
                 (string k)))
             (get node :keys)))
      (def aggs (get node :aggs))
      (defn agg-col [a]
        (unless (and (dictionary? (get a :arg)) (= :get (get (get a :arg) :expr)))
          (jq/err :malformed-tree
                  {:why :rayforce-agg-column :node a :backend :rayforce}))
        (fence s0 (get (get a :arg) :col) (get (get a :arg) :alias)
               :group-agg-row-scope node))
      (def agg-cols (map agg-col aggs))
      # the output names the group will carry, refused when they collide:
      # the engine tolerates duplicate column names but its two read paths
      # disagree on one (table-column resolves the first, table-columns
      # keeps the last), and the numeric branch below renames onto these
      # names, which rf/-table-alias refuses. Raised before the engine
      # runs, so the class does not depend on the payload's column types.
      (def out-names
        (tuple ;key-out
                ;(map (fn [a] (jq/expr-name a)) aggs)))
      (when-let [dup (-duplicate-name out-names)]
        (jq/err :malformed-tree
                {:why :rayforce-duplicate-output-name :node node
                 :name dup :backend :rayforce}))
      (def g (get s0 :g))
      (def op (rf/group g
                         (map (fn [nm] (scan-for s0 nm)) key-names)
                         (map (fn [i] [(scan-for s0 (agg-cols i))
                                       (get (aggs i) :agg)])
                              (range (length aggs)))))
      (def res (rf/execute g op))
      (defer (close-segment s0)
        # engine agg outputs are named col_agg; the contract names are
        # agg_col (expr-name, the duckdb convention) - decode by the
        # engine names, surface the contract names
        (def engine-names
          (tuple ;(map (fn [k] (get k :name)) key-names)
                  ;(map (fn [i] (string (get (agg-cols i) :name) "_"
                                        (get agg-engine-name
                                             (get (aggs i) :agg))))
                       (range (length aggs)))))
        # An all-numeric payload never leaves the engine: the executed
        # table is aliased to the contract names and handed back as a
        # SEGMENT, so a following order/limit composes engine-side in a
        # fresh graph (the group rows are never decoded, the materialise
        # boundary and the janet-side re-ingest both vanish). Any other
        # column type stays on the decode path, where the STR/SYM
        # fences live.
        (if (and (-numeric-table? res)
                 (deep= (-engine-names res) engine-names))
          (defer (:close res)
            (new-segment (-table-alias res engine-names out-names node)
                         out-names true))
          (do
            (def cols (decode-ordered res engine-names))
            @{:kind :result :res res :cols cols :out out-names
              :engine-names engine-names}))))
    (jq/err :malformed-tree
            {:why :rayforce-node :node node :backend :rayforce})))

# exception: returns a derived value, raises the backend class; a
# return guard would mask it
(defn alias-of
  "The effective side alias of a join side (the from's :alias or a
generated side name)."
  [tree side]
  (if (and (struct? tree) (get tree :alias)) (string (get tree :alias)) side))

# exception: returns a derived value, raises the backend class; a
# return guard would mask it
(defn base-from
  "The from/from-parquet node at the bottom of a chain."
  [tree]
  (if (and (struct? tree) (get tree :input)) (base-from (get tree :input)) tree))

(defn/typed side-source {:args [:any :any] :ret :table}
  [s node]
  "A compiled join side -> a plain source table. RESULT and applied
segments execute first (join needs table handles). A side whose columns are
all I64/F64 is ALIASED to its contract names zero-copy: names only, no
decode, no re-ingest (the values never leave the engine). A side carrying
any other engine type takes the decode path, which is where the numeric
boundary fence fires. Returns @{:tbl :cols :owned}."
  (cond
    (= (get s :kind) :result)
    (let [names (tuple ;(get s :out))
          res (get s :res)]
      (if (and (-numeric-table? res)
               (deep= (-engine-names res) (get s :engine-names)))
        (let [t (-table-alias res (-engine-names res) names node)]
          (:close res)
          @{:tbl t :cols names :owned true})
        (do
          (check-numeric-boundary (get s :cols) node)
          (def t (ingest names (get s :cols)))
          (:close res)
          @{:tbl t :cols names :owned true})))
    (or (get s :op) (get s :pred))
    (let [res (rf/execute (get s :g) (root-op s))
          names (tuple ;(get s :out))
          dnames (tuple ;(get s :decode-names))]
      (defer (close-segment s)
        (if (and (-numeric-table? res) (deep= (-engine-names res) dnames))
          (let [t (-table-alias res dnames names node)]
            (:close res)
            @{:tbl t :cols names :owned true})
          (do
            (def cols (decode-ordered res dnames))
            (check-numeric-boundary cols node)
            (def t (ingest names cols))
            (:close res)
            @{:tbl t :cols names :owned true}))))
    # a join segment carries its full column set in :out (its :cols is the
    # left side's, a handle restriction of the engine join); every other
    # segment's :cols is its output
    @{:tbl (get s :tbl) :cols (tuple ;(get s (if (get s :side-map) :out :cols)))
       :owned (get s :owned)}))

(defn/typed join-stage {:args [:any :any :any] :ret :table}
  [L R node]
  "Two compiled sides -> the join SEGMENT. Collision renames (the
  alias-by-renamed-copy strategy): when the sides share column names
  (always true for a same-table self-join), both sides get alias-qualified
  copies - the engine collapses same-named join output columns into a
  cross-side mix (probe-verified) and there is no rename op, so the names
  are the only control. A numeric side's copy is ZERO-COPY (the column
  vectors are retained, not decoded: -table-alias); any other type takes the
  decode path, whose STR fence is the documented :rayforce-str-join-rename
  class. When the two key columns would mix storage types both sides take
  the decode path, so the raw-payload rule can never fire where the
  pre-fix shape matched by value. The output is always projected by the
  post-chain (never-surface-unprojected-join)."
  (def La (alias-of (base-from (get node :left)) "l"))
  (def Ra (alias-of (base-from (get node :right)) "r"))
  (def lsrc0 (side-source L node))
  (def rsrc0 (side-source R node))
  # The join compares keys by RAW PAYLOAD: the two key columns must carry the
  # same engine type. The zero-copy alias keeps a side's I64 columns
  # I64, where the decode path re-ingests every column as F64 - so when a key
  # pair would MIX types, both sides take the decode path (the pre-fix shape
  # had them F64/F64 by construction).
  (defn keys-mixed? [ls rs]
    (def lks (get node :lkeys))
    (def rks (get node :rkeys))
    (var mixed false)
    (for i 0 (min (length lks) (length rks))
      (def lt (-col-tag (get ls :tbl) (string (lks i))))
      (def rt (-col-tag (get rs :tbl) (string (rks i))))
      (when (and (pos? lt) (pos? rt) (not= lt rt)) (set mixed true)))
    mixed)
  (defn decode-side [src]
    "The decode path for one side, under the side's own names: the STR
    fence fires on the decoded values, and the re-ingest is all-F64 as
    before. Closes an owned source table."
    (def pairs
      (map (fn [nm] [nm (rf/table-column (get src :tbl) nm)]) (get src :cols)))
    (each [_ arr] pairs
      (each v arr
        (when (or (string? v) (buffer? v))
          (jq/err :malformed-tree
                  {:why :rayforce-str-join-rename :node node
                   :backend :rayforce}))))
    (when (get src :owned) (:close (get src :tbl)))
    @{:tbl (ingest (get src :cols) (map last pairs))
      :cols (get src :cols) :owned true})
  (def mixed (keys-mixed? lsrc0 rsrc0))
  (def lsrc (if mixed (decode-side lsrc0) lsrc0))
  (def rsrc (if mixed (decode-side rsrc0) rsrc0))
  (def lcols (get lsrc :cols))
  (def rcols (get rsrc :cols))
  (def collide
    (not (empty? (filter (fn [nm] (index-of nm rcols)) lcols))))
  (defn renamed-copy [src alias]
    (def names (map (fn [nm] (string alias "." nm)) (get src :cols)))
    (if (-numeric-table? (get src :tbl))
      # numeric side: alias-qualify the names, share the column vectors
      (let [t (-table-alias (get src :tbl) (get src :cols) names node)]
        (when (get src :owned) (:close (get src :tbl)))
        @{:tbl t :cols (tuple ;names) :owned true})
      # any other type takes the decode path, whose STR fence is the
      # documented :rayforce-str-join-rename class
      (do
        (def d (decode-side src))
        (def t (-table-alias (get d :tbl) (get src :cols) names node))
        (:close (get d :tbl))
        @{:tbl t :cols (tuple ;names) :owned true})))
  (def l* (if collide (renamed-copy lsrc La) lsrc))
  (def r* (if collide (renamed-copy rsrc Ra) rsrc))
  (def lkey-names
    (map (fn [k] (string (if collide (string La ".") "") k)) (get node :lkeys)))
  (def rkey-names
    (map (fn [k] (string (if collide (string Ra ".") "") k)) (get node :rkeys)))
  # join-key scope fence: keys resolve against their side's columns
  (each [ks side] [[(tuple ;lkey-names) (get l* :cols)]
                    [(tuple ;rkey-names) (get r* :cols)]]
    (each k ks
      (unless (index-of k side)
        (jq/err :malformed-tree
                {:why :rayforce-join-key-scope :node node :name k
                 :backend :rayforce}))))
  (def g (rf/graph (get l* :tbl)))
  (def tid (rf/add-table g (get r* :tbl)))
  (def lops (map (fn [k] (rf/scan g k)) lkey-names))
  (def rops (map (fn [k] (rf/scan-table g tid k)) rkey-names))
  (def jop (rf/join g (rf/const-table g (get l* :tbl)) lops
                    (rf/const-table g (get r* :tbl)) rops (get node :type)))
  # the side-map maps each side's ORIGINAL column names to the join
  # output names (plain on a collision-free join, alias-qualified on a
  # renamed-copy join) - positionally paired, the rename preserves order.
  # A renamed copy is an ADDED table, so its columns need scan-table
  # (a bound-graph scan is refused for them): the emit resolves through
  # :col-tid (the join-side add-table id) or nil for the left side.
  (defn side-map-entry [alias orig-cols final-cols rhs?]
    [(string alias)
     (table ;(mapcat (fn [i]
                       [(orig-cols i)
                        @{:name (final-cols i)
                          :col-tid (if rhs? tid nil)}])
                     (range (length orig-cols))))])
  # the engine's join output is the LEFT side's columns plus the right
  # side's columns whose NAMES are absent from the left (probe-verified:
  # a non-colliding join returns the left table's columns plus the right
  # table's uniquely-named ones; a renamed-copy join returns every
  # alias-qualified name - both sides then differ in name). The keys are
  # scanned but the right key column never survives under its own name,
  # so :out must be the engine's set, not the naive union (a decode over
  # the union reads a phantom column)
  (def out-cols
    (tuple ;(reduce (fn [acc nm] (if (index-of nm acc) acc (array/push acc nm)))
                    @[] (tuple ;(get l* :cols)
                               ;(filter (fn [nm]
                                          (and (not (index-of nm (get l* :cols)))
                                               (not (index-of nm rkey-names))))
                                        (get r* :cols))))))
  @{:kind :segment :g g :tbl (get l* :tbl) :cols out-cols
  :out out-cols
  :scan-scope out-cols
  :col-tid nil
  :decode-names out-cols
  :op jop :pred nil :applied true
    :owned (get l* :owned) :side-map
    @{;(side-map-entry La (get lsrc :cols) (get l* :cols) false)
      ;(side-map-entry Ra (get rsrc :cols) (get r* :cols) true)}
    :left-cols (get l* :cols)
    :tid tid :right-cols (get r* :cols)
    :right-tbl (get r* :tbl) :close-right (get r* :owned)})

(defn/typed compile-node {:args [:any] :ret :table}
  [tree]
  "Tree -> SEGMENT or RESULT state."
  (def n (get tree :node))
  (cond
    (= n :join)
    (join-stage (compile-node (get tree :left))
                (compile-node (get tree :right)) tree)
    (or (= n :from) (= n :from-parquet))
    (let [src (source-table tree)]
      (new-segment (get src :tbl) (get src :cols) (get src :owned)))
    (get tree :input)
    (let [s (compile-node (get tree :input))]
      (cond
        # a projection over a decoded group/distinct result is a
        # JANET-SIDE column pick (no re-ingest) - a STR-bearing
        # terminal group stays decodable through a select
        (and (= (get s :kind) :result)
             (= :select (get tree :node)))
        (do
          (def sel (get tree :cols))
          (if (empty? sel)
            s
            (let [picks
                  (map (fn [c]
                         (def nm (if (and (struct? c)
                                          (= :get (get c :expr)))
                                   (string (get c :col))
                                   (string c)))
                         (unless (index-of nm (get s :out))
                           (jq/err :malformed-tree
                                   {:why :filter-pred-row-scope
                                    :node tree :name nm
                                    :backend :rayforce}))
                         nm)
                       sel)]
              @{:kind :result :res (get s :res)
                :cols (map (fn [nm] (get (get s :cols)
                                         (index-of nm (get s :out))))
                           picks)
                :out (tuple ;picks)})))
        (= (get s :kind) :result)
        (apply-node (result->segment s tree) tree)
        (apply-node s tree)))
    (jq/err :malformed-tree
            {:why :rayforce-node :node tree :backend :rayforce})))

#==------------------------------------------------------------------------==#
# The engine form + execute (the DAG is built inside execute)
#==------------------------------------------------------------------------==#

(defn/typed normalise-nan {:args [:any] :ret :any}
  [x]
  "Literal NaN -> explicit NULL, everywhere in a node tree. The f64 lane
has ONE null encoding (any NaN IS a null), so a NaN literal
can only mean NULL here; spelling it at the render means the carrier
tree states what the engine will do, instead of the engine folding it
silently. Structural walk: a struct/buffer/tuple rebuilds, a table
rebuilds into a table (the caller's tree is never mutated)."
  (cond
    (nan? x) nil
    (dictionary? x)
    (let [out (table/new (length x))]
      (eachp [k v] x (put out k (normalise-nan v)))
      # keep the node's own representation: downstream matches on structs
      (if (table? x) out (struct ;(kvs out))))
    # a buffer carries BYTES: `(buffer ;out)` would stringify each byte into
    # its decimal digits, so its bytes are copied
    (buffer? x) (let [out (buffer/new (length x))]
                  (each b x (buffer/push-byte out b))
                  out)
    (or (tuple? x) (array? x))
    (let [n (length x)
          out (array/new n)]
      (each v x (array/push out (normalise-nan v)))
      (if (tuple? x) (tuple ;out) out))
    x))

(defn/typed render-form {:args [:any] :ret :table}
  [tree]
  "Node tree -> the rayforce engine form: a CARRIER (the tree plus the
plan-shape marker). The DAG itself is built per EXECUTION - the
fresh-graph rule: a rendered form is inert data, safe to hold and re-execute on a
fresh graph; no op object survives between calls.

The carrier tree is the OBSERVABLE render contract for this backend: a
literal NaN is rendered as explicit NULL (normalise-nan above), so the
form a caller holds says NULL rather than NaN. NaN literals have no
second meaning on the f64 lane, which is why the normalisation is safe
at render rather than at the engine boundary."
  @{:backend :rayforce :tree (normalise-nan tree) :form :dag-per-execution})

(defn/typed decode-state {:args [:any] :ret :table}
  [s]
  "A terminal state -> the result wrapper: executes the final segment
(or decodes a group/distinct RESULT directly - no re-ingest, STR keys
and type-agnostic aggs decode to the wrapper), rows positional arrays
aligned to :columns, NULL -> nil, NaN -> nil (the unified mapping,
documented divergence from duckdb's NaN-distinct payload)."
  (if (= (get s :kind) :result)
    (do
      (def cols (get s :cols))
      (def names (tuple ;(get s :out)))
      (def n (if (empty? names) 0 (length (cols 0))))
      (def rows
        (seq [i :range [0 n]]
          (tuple ;(map (fn [c] (get c i)) cols))))
      (jq/wrap-result @[;rows] @[;(map keyword names)]))
    (let [[res cols] (exec-decode s)
          names (get s :out)
          n (if (empty? names) 0 (length (cols 0)))]
      (defer (do (:close res) (close-segment s))
        (def rows
          (seq [i :range [0 n]]
            (tuple ;(map (fn [c] (get c i)) cols))))
        (jq/wrap-result @[;rows] @[;(map keyword names)])))))

(defn/typed exec-form {:args [:any] :ret :table}
  [form]
  "Engine form -> the one result wrapper. Builds every graph fresh
 inside the call, closes every backend-owned handle on its path
 (net 0, measured under ray_mem_trace), decodes through the STR-copy
 path. The two alignment fences and the scope fences raise the
 malformed-tree class before any engine call on their lanes;
 engine-detected misuse surfaces the module's typed errors (the
 error-class asymmetry the README documents)."
  (def s (compile-node (get form :tree)))
  (if (= (get s :kind) :result)
    (defer (close-result s)
      (decode-state s))
    (decode-state s)))

#==------------------------------------------------------------------------==#
# Registration and the backend's compatibility matrix
#==------------------------------------------------------------------------==#

(def rayforce-matrix
  "The v1 rayforce compatibility matrix:
the shared set, where-as-filter (two-valued nulls, documented
divergence), join inner/left/full (null-matching keys), the
floor-lane idiv/mod expressions. DENIED - named gaps, never
substituted: :join-anti (jtype-3 silently returns left-join output,
ray_antijoin unbound), :asof/:wco (unbound), :window (ray_window_op
unbound), :count-distinct, :median (absent agg), :append
(ray_lazy_append unbound), :write-parquet (no parquet write surface),
:escape (a pre-built op handle is graph-scoped; the fresh-graph
rule makes a static splice stale - the splice form needs a
janet-rayforce slice), :expr-in/:expr-not-in (ray_in unbound). One
further divergence vs duckdb, named: a group whose output names
would collide (a group key and an agg over another column resolving to
the same name, e.g. key :sum_x with (sum (get :x)), or two aggs sharing
a name) raises the malformed-tree class (`:why
:rayforce-duplicate-output-name`) instead of being served; duckdb
returns both columns. The engine's two read paths disagree on a
duplicate name, so a serve would read back ambiguously; the refusal
replaces a silent-wrong."
  {:from :shared :group :shared :select :shared :order :shared
   :limit :shared :distinct :shared :from-parquet :shared
   :where :native :join :native
   :expr-idiv :native :expr-mod :native})

(jq/register-backend!
  @{:name :rayforce
    :renderer render-form
    :execute exec-form
    :catalog-spec @{}
    :matrix rayforce-matrix})

(jq/add-manifest! :rayforce
  {"from|base" "s3-rf-from"
   "from|dataset" "s3-rf-dataset"
   "from|handle" "s3-rf-handle"
   "from|unbindable" "s3-rf-unbindable"
   "from-parquet|base" "s3-rf-parquet"
   "from-parquet|str" "s3-rf-parquet-str"
   "select|base" "s3-rf-select"
   "select|expression-denied" "s3-rf-select-expr"
   "order|base" "s3-rf-order"
   "order|nulls" "s3-rf-order-nulls"
   "limit|head" "s3-rf-limit"
   "limit|tail" "s3-rf-limit-tail"
   "distinct|base" "s3-rf-distinct"
   "distinct|null" "s3-rf-distinct-null"
   "group|base" "s3-rf-group"
   "group|rename" "s3-rf-group-rename"
   "group|null-key" "s3-rf-group-nullkey"
   "group|str-key" "s3-rf-group-strkey"
   "group|str-agg" "s3-rf-group-stragg"
   "where|base" "s3-rf-where"
   "where|null-two-valued" "s3-rf-where-null"
   "where|merge" "s3-rf-where-merge"
   "where|fence" "s3-rf-fence-pred"
   "group|fence" "s3-rf-fence-agg"
   "join|base" "s3-rf-join"
   "join|null-key" "s3-rf-join-nullkey"
   "join|self-alias" "s3-rf-join-self"
   "join|key-scope" "s3-rf-join-keyscope"
   "deny|anti" "s3-rf-deny-anti"
   "expr-idiv|base" "s3-rf-idiv"
   "expr-mod|base" "s3-rf-idiv"
   "limit|base" "s3-rf-limit"
   "deny|count-distinct" "s3-rf-deny-cd"
   "deny|median" "s3-rf-deny-median"
   "deny|append" "s3-rf-deny-append"
   "deny|write-parquet" "s3-rf-deny-write"
   "deny|window" "s3-rf-deny-window"
   "deny|in" "s3-rf-deny-in"
   "deny|escape" "s3-rf-deny-escape"
   "expr|core" "s3-rf-expr"
   "expr|idiv-floor" "s3-rf-idiv"
   "leak|cycle" "s3-rf-leak"
   "cd-expansion|engine" "s5-cd-engine"
   "cd-expansion|idempotence" "s5-cd-idem"
   "cd-expansion|leak" "s5-cd-leak"
   "cd-expansion|crash" "s5-cd-crash"
   "cd-expansion|nested" "s5-cd-nested"
   "equiv|dual-shared" "s3-rf-equiv"
   "equiv|where-nullfree" "s3-rf-equiv-where"
   "equiv|join-nullfree" "s3-rf-equiv-join"
   "diverge|where-null" "s3-rf-diverge-where"
   "diverge|nan" "s3-rf-diverge-nan"
   "result|wrapper" "s3-rf-wrapper"})
