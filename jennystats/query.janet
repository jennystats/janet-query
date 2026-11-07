# jennystats/query.janet  -  the engine-agnostic compositional query layer.
#
# Part of janet-query (module jennystats/query). License: AGPLv3 (see
# LICENSE). The README carries the node set, the backend contract, the
# result shape, the error grammar and the ordering/equivalence semantics.
#
# The spine: queries are inert Janet values (node structs) composed by ->
# threading; a backend is a TRANSLATOR (renderer + execute function +
# compatibility matrix) registered explicitly via register-backend!. One
# query, one backend, per execution - no default backend, ever.
#
# Core is backend-blind: it knows the node grammar, the intersection rule
# (the shared set + per-backend extension declarations), backend selection
# precedence and the error grammar - nothing about any engine. The denial
# machine's properties (a)-(e) are mirrored by the runtime checks in this
# module.
#
# Bounds: where/join are per-backend extensions;
# count-distinct is duckdb-native or backend-declared expansion;
# median is a duckdb extension; window/pivot/wco are grammar nodes denied
# by every v1 backend. Scope note: the backends registry is a plain module
# table - entries are validated at register-backend! but the table itself
# is module-env reachable; forged entries bypass validation by design
# boundary (the same class as the rayforce binding's shape-only handle fencing).
#
# Variadic constructors use plain defn - defn/typed is fixed-arity only
# (typed.janet); every fixed-arity function below is defn/typed.
#
# Public API:
#   nodes: from, where, join, group, select, order, limit, distinct,
#          append, from-parquet, write-parquet, escape, window, pivot
#   scalars: lit, get, add, sub, mul, div, idiv, mod, eq, ne, lt, le, gt,
#          ge, and2, or2, not2, isnull, min2, max2, if2, in, not-in
#   aggregates: sum, avg, count, count-distinct, min, max, first, last,
#          stddev, var, median
#   machinery: register-backend!, defquery (macro), render, execute,
#          wrap-result, coverage-manifest

(import jennystats/typed :prefix "")

#==------------------------------------------------------------------------==#
# Grammar constants (contract section 3, v0.3 final)
#==------------------------------------------------------------------------==#

(def shared-ops
  "The v1 shared set - every registered backend MUST declare each of
these (intersection rule; the registration validator enforces it).
:append and :write-parquet are not in the shared set - the rayforce
engine has no append operator and no parquet write surface; both stay
duckdb-declared extensions."
  [:from :group :select :order :limit :distinct :from-parquet])

(def extension-ops
  "Known per-backend operators beyond the shared set. Absent from a
backend's matrix = denied at expansion with operator + backend named."
  [:where :join :join-anti :asof :wco :escape :count-distinct :median
   :window :pivot :append :write-parquet
   :expr-in :expr-not-in :expr-idiv :expr-mod])

(def known-ops (tuple ;shared-ops ;extension-ops))

(def expr-ops
  "Scalar expression call operators (contract 3.3; idiv/mod/in/not-in
are per-backend lanes, matrix-gated via :expr-idiv/:expr-mod/:expr-in/
:expr-not-in)."
  [:add :sub :mul :div :idiv :mod :eq :ne :lt :le :gt :ge
   :and :or :not :isnull :min2 :max2 :if :in :not-in])

(def agg-ops
  "Aggregate operators (contract 3.1/3.2; count-distinct and median are
matrix-gated lanes)."
  [:sum :avg :count :count-distinct :min :max :first :last :stddev
   :var :median])

(def ctor-names
  "The defquery-scope constructor set (DSL surface 5: bare names)."
  '[from where join group select order limit distinct append
    from-parquet write-parquet escape window pivot
    lit get add sub mul div idiv mod eq ne lt le gt ge
    and2 or2 not2 isnull min2 max2 if2 in not-in
    sum avg count count-distinct min max first last stddev var median])

#==------------------------------------------------------------------------==#
# Error grammar (contract section 5 - one shape across the module)
#==------------------------------------------------------------------------==#

(defn/typed err {:args [:keyword :struct] :ret :struct} [kind facts]
  "Raise the contract error shape: a struct always carrying :error."
  (error (table/to-struct (merge {:error kind} facts))))

(defn/typed check! {:args [:any :keyword :struct] :ret :any} [v kind facts]
  "Raise the contract error shape when v is nil/false."
  (unless v (err kind facts))
  v)

#==------------------------------------------------------------------------==#
# Node constructors (inert values; validation is expansion's job)
#==------------------------------------------------------------------------==#

(defn/typed uniq {:args [:any] :ret :tuple}
  [xs]
  "Order-preserving duplicate removal (no dedup in core 1.42.1);
returns a tuple so rewritten node values stay inert tuples."
  (def seen @{})
  (def out @[])
  (each x xs (unless (get seen x) (put seen x true) (array/push out x)))
  (tuple ;out))

# exception: varargs + key parsing - the raise carries the malformed class, not a guard
(defn parse-kw-args
  "Varargs of alternating keyword/value pairs to a struct; an odd tail
or a non-keyword key raises the malformed-tree class."
  [& args]
  (when (odd? (length args))
    (err :malformed-tree {:node {:args args} :why :odd-keyword-args}))
  (def out @{})
 (var i 0)
  (while (< i (length args))
    (def k (args i))
    (unless (keyword? k)
      (err :malformed-tree {:node {:args args} :why :non-keyword-arg-key}))
    (put out k (args (inc i)))
    (+= i 2))
  (table/to-struct out))

# exception: optional :alias keyword - &opt arity, the fixed-arity
# defn/typed cannot express it
(defn from
  "Source node: (from :table) or (from :table :alias :e1). The source
is a table name (keyword/string, resolved against the catalog), a
parquet path string, or a backend-bound handle (a struct/table whose
:backend key carries its provenance)."
  [src & args]
  (def kw (parse-kw-args ;args))
  {:node :from :src src :alias (get kw :alias)})

# exception: optional :alias keyword - &opt arity, the fixed-arity
# defn/typed cannot express it
(defn from-parquet
  "Parquet source node: (from-parquet \"path/to/file.parquet\"), same
keyword args as from (alias, and src - a handle whose :backend carries
the source's backend provenance, contract 4.3)."
  [path & args]
  (def kw (parse-kw-args ;args))
  {:node :from-parquet :path path :alias (get kw :alias)
   :src (get kw :src)})

(defn/typed where {:args [:any :any] :ret :struct}
  [tree pred]
  "Per-backend extension node: (where tree pred-expr)."
  {:node :where :pred pred :input tree})

(defn normalize-agg
  "One aggregate argument as the walk expects it: an :agg node passes
through, and a one-element collection is unwrapped (a vector literal
arrives compile-time folded into a tuple, which the variadic slot would
otherwise carry as a second level)."
  [a]
  (cond
    (and (or (struct? a) (table? a)) (= :agg (get a :expr))) a
    (and (indexed? a)
         (= 1 (length a))
         (or (struct? (first a)) (table? (first a)))
         (= :agg (get (first a) :expr))) (first a)
    true a))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn key-list
  "Key-list slots for the node constructors: a tuple/list passes through,
any other collection becomes a tuple of its elements, and a keyword (or
string) key becomes a one-element tuple. Reference / literal nodes stay
atoms so the walk judges them as they arrive."
  [k]
  (cond
    (tuple? k) k
    (indexed? k) (tuple ;k)
    (or (keyword? k) (string? k) (bytes? k)) [k]
    true k))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn join
  [left right lkeys rkeys &opt jtype]
  "Per-backend extension node: (join ltree rtree lkeys rkeys
&opt jtype). Keys are a keyword or tuple of keywords; jtype one of
:inner :left :full :anti :asof :wco (variant lanes are matrix-gated:
:asof/:wco appear as their own matrix keys)."
  (def j (or jtype :inner))
  {:node :join :type j
   :left left :right right
   :lkeys (key-list lkeys) :rkeys (key-list rkeys)})

# exception: variadic aggregate/projection lists - & arity
(defn group
  "Shared aggregate node: (group tree keys & aggs). Keys: keyword or
tuple of keywords; aggs: zero or more aggregate expressions built by
the aggregate constructors. Output columns are the keys (their own
names) plus one per agg named (agg-op_col) - see the module README."
  [tree keys & aggs]
  (def keyed (key-list keys))
  (def agg-list (tuple ;(map normalize-agg aggs)))
  {:node :group
   :keys keyed
   :aggs agg-list
   :input tree})

# exception: variadic aggregate/projection lists - & arity
(defn select
  "Shared projection node (source-named, P14): (select tree & cols).
Each col: a keyword/string column name or an expression node."
  [tree & cols]
  {:node :select :cols (tuple ;cols) :input tree})

# exception: variadic aggregate/projection lists - & arity
(defn order
  "Shared ordering node: (order tree & keys). Each key: col, or
[col :asc]/[col :desc]."
  [tree & keys]
  (def ks
    (seq [k :in keys]
      (if (indexed? k)
        (do (unless (= 2 (length k))
              (err :malformed-tree {:node {:key k} :why :order-key-pair}))
            {:col (k 0) :dir (k 1)})
        {:col k :dir :asc})))
  {:node :order :keys (tuple ;ks) :input tree})

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn limit
  [tree n &opt form]
  "Shared limit node: (limit tree n &opt form), form :head (default)
or :tail."
  {:node :limit :n n :form (or form :head) :input tree})

(defn/typed node-distinct {:args [:any] :ret :struct}
  [tree]
  "Shared distinct node: distinct rows of tree. (Exported as
`distinct` at file end - core `distinct` must stay bound through the
module body.)"
  {:node :distinct :input tree})

# exception: variadic tree operands - & arity
(defn append
  "Shared UNION ALL node: (append t1 t2 ...), position-aligned
columns (NOT union-by-name); column-count mismatch raises the
malformed-tree class naming this node (expansion time)."
  [& sides]
  {:node :append :sides (tuple ;sides)})

(defn/typed write-parquet {:args [:any :any] :ret :struct}
  [tree path]
  "Shared sink node: (write-parquet tree \"path.parquet\")."
  {:node :write-parquet :path path :input tree})

(defn/typed escape {:args [:any :any] :ret :struct}
  [backend text]
  "Backend-tagged escape hatch (contract 3.4): (escape :duckdb
\"SQL FRAGMENT\"). Non-portable by construction: renders on exactly
the tagged backend, extension-denied on every other."
  {:node :escape :backend backend :text text})

# exception: optional keyword tail - &opt arity
(defn window
  "Grammar-only node (contract 3.5: present in the grammar, denied by
every v1 backend - ray_window_op unbound on janet-rayforce 0.1.1)."
  [tree & args]
  {:node :window :spec (parse-kw-args ;args) :input tree})

# exception: optional keyword tail - &opt arity
(defn pivot
  "Grammar-only node (pivot unbound on janet-rayforce 0.1.1; duckdb
has no plan-level counterpart)."
  [tree & args]
  {:node :pivot :spec (parse-kw-args ;args) :input tree})

#==------------------------------------------------------------------------==#
# Scalar expression builders (contract 3.3)
#==------------------------------------------------------------------------==#

(defn/typed lit {:args [:any] :ret :struct} [v]
  "Literal value: a bound parameter at render, never interpolated
text (the :log-p class of bug is impossible by construction)."
  {:expr :lit :value v})

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn col2
  [c &opt a]
  "Column reference: (get :col) or (get :col :alias) - alias qualifies
the from-node's :alias (self-join lanes, P14). Defined as col2 and
exported as `get` at file end - core `get` must stay bound through
the module body (hundreds of internal uses)."
  (check! (or (keyword? c) (string? c)) :malformed-tree
          {:node {:col c} :why :column-name-type})
  (when a (check! (or (keyword? a) (string? a)) :malformed-tree
                  {:node {:alias a} :why :alias-name-type}))
  {:expr :get :col (if (string? c) (keyword c) c) :alias (if (string? a) (keyword a) a)})

(defmacro defexprop
  "Define a fixed-arity scalar builder emitting a :call expr node."
  [name op arity]
  (def params (tuple ;(map |(symbol (string "x" (inc $))) (range arity))))
  ~(defn ,name
     ,(string "Scalar builder for the " op " operator.")
     [,;params]
     {:expr :call :op ,op :args (tuple ,;params)}))

(defexprop add :add 2)
(defexprop sub :sub 2)
(defexprop mul :mul 2)
(defexprop divx :div 2)
(defexprop idiv :idiv 2)
(defexprop modx :mod 2)
(defexprop eq :eq 2)
(defexprop ne :ne 2)
(defexprop lt :lt 2)
(defexprop le :le 2)
(defexprop gt :gt 2)
(defexprop ge :ge 2)
(defexprop and2 :and 2)
(defexprop or2 :or 2)
(defexprop not2 :not 1)
(defexprop isnull :isnull 1)
(defexprop min2 :min2 2)
(defexprop max2 :max2 2)
(defexprop if2 :if 3)

(defn/typed in {:args [:any :any] :ret :struct}
  [x vals]
  "Membership: (in x [v1 v2 ...]) - the literal set is bound
parameters, not interpolated text; raw values wrap as literals."
  (check! (indexed? vals) :malformed-tree {:node {:in vals} :why :set-not-indexed})
  {:expr :call :op :in :args (tuple x ;(map |(if (struct? $0) $0 (lit $0)) vals))})

# exception: variadic tree operands - & arity
(defn not-in
  "Negated membership: (not-in x [v1 v2 ...]); raw values wrap as
literals."
  [x vals]
  (check! (indexed? vals) :malformed-tree {:node {:not-in vals} :why :set-not-indexed})
  {:expr :call :op :not-in :args (tuple x ;(map |(if (struct? $0) $0 (lit $0)) vals))})

#==------------------------------------------------------------------------==#
# Aggregate builders (contract 3.1; count-distinct/median matrix-gated)
#==------------------------------------------------------------------------==#

(defmacro defaggop
  "Define an aggregate builder emitting an :agg expr node. A bare
keyword or string argument names a column and is normalised to the
(get :col) form: one aggregate node whatever the
argument's spelling, so `(count :c)` and `(count (get :c))` are the
same tree node. The string spelling is normalised to a KEYWORD column
name: `(count \"c\")` and `(count :c)` must be equal
as nodes, and the string form would otherwise carry a string :col."
  [name op]
  ~(defn ,name
     ,(string "Aggregate builder for " op ".")
     [e]
     {:expr :agg :agg ,op
      :arg (cond
             (keyword? e) {:expr :get :col e :alias nil}
             (string? e) {:expr :get :col (keyword e) :alias nil}
             e)}))

(defaggop sum :sum)
(defaggop avg :avg)
(defaggop agg-count :count)
(defaggop count-distinct :count-distinct)
(defaggop agg-min :min)
(defaggop agg-max :max)
(defaggop agg-first :first)
(defaggop agg-last :last)
(defaggop stddev :stddev)
(defaggop agg-var :var)
(defaggop median :median)

#==------------------------------------------------------------------------==#
# The tree pass (contract 4 expansion + section 7 manifest attachment)
#==------------------------------------------------------------------------==#

(defn/typed expr?* {:args [:any] :ret :boolean} [e]
  "Is e a structurally valid expression node (recursive). An escape
node is a valid expression ATOM (contract 3.4: a fragment spliced
at a defined position)."
  (and (struct? e)
       (if (= :escape (get e :node))
         (and (keyword? (get e :backend)) (string? (get e :text)))
         (case (get e :expr)
         :lit true
         :get (and (or (keyword? (get e :col)) (string? (get e :col)))
                   (or (nil? (get e :alias))
                       (keyword? (get e :alias)) (string? (get e :alias))))
         :call (and (not (nil? (index-of (get e :op) expr-ops)))
                    (indexed? (get e :args))
                    (all expr?* (get e :args))
                    true)
         :agg (and (not (nil? (index-of (get e :agg) agg-ops)))
                   (expr?* (get e :arg)))
         false))))

(defn/typed valid-expr {:args [:any :keyword] :ret :any}
  [e what]
  (check! (expr?* e) :malformed-tree {:node e :why what})
  e)

(defmacro ident-key [x]
  "A memoisation key for a value: tables key by the value itself, structs
by their hash, atoms by value. Used ONLY by the seen-sets that make a
shared subtree walk once (a diamond costs linear in node count); a hash
collision merges two structs' memos, which can only over-visit a shared
node, never hide a cycle - the cycle check is seen*/enter*, which compares
path VALUES with `=`. The former wording here ('hash plus declaration
order') described a second key component `;(keys x)` that never changed the
verdict: janet's struct hash and `=` agree on layout (probed over
2000 reordered pairs - zero content-equal structs hashed apart, zero
layout-only hash differences)."
  ~(cond (table? ,x) ,x (struct? ,x) (tuple :struct (hash ,x)) ,x))

(defn/typed agg-ops-of {:args [:any] :ret :tuple}
  [tree]
  "The aggregate operators named by a tree (group node arg lists)."
  (def out @[])
  (def seen @{})
  (defn walk [t]
    (when (struct? t)
      (def id (ident-key t))
      (unless (get seen id)
        (put seen id true)
        (when (= :query (get t :node)) (walk (get t :tree)))
        (case (get t :node)
          :group (each a (if (indexed? (get t :aggs)) (get t :aggs) [])
                   (when (and (struct? a) (= :agg (get a :expr)))
                     (array/push out (get a :agg))))
          nil)
        (walk (get t :input))
        (when (get t :sides) (each s (get t :sides) (walk s)))
        (when (get t :left) (walk (get t :left)))
        (when (get t :right) (walk (get t :right)))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  (uniq out))

(defn/typed expr-calls-of {:args [:any] :ret :tuple}
  [tree]
  "The scalar call operators named by a tree."
  (def out @[])
  (def seen @{})
  (defn walk-e [e]
    (when (and (struct? e) (= :call (get e :expr)))
      (array/push out (get e :op))
      (each a (get e :args) (walk-e a))))
  (defn walk [t]
    (when (struct? t)
      (def id (ident-key t))
      (unless (get seen id)
        (put seen id true)
        (when (= :query (get t :node)) (walk (get t :tree)))
        (walk-e (get t :pred))
        (when (get t :keys) (each k (get t :keys) (when (struct? k) (walk-e k))))
        (when (get t :cols) (each c (get t :cols) (when (struct? c) (walk-e c))))
        (when (get t :aggs)
          (each a (if (indexed? (get t :aggs)) (get t :aggs) [])
            (walk-e a)
            (when (struct? a) (walk-e (get a :arg)))))
        (when (get t :input) (walk (get t :input)))
        (when (get t :sides) (each s (get t :sides) (walk s)))
        (when (get t :left) (walk (get t :left)))
        (when (get t :right) (walk (get t :right)))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  (uniq out))

# Cycle detection walks carry a PATH (the ancestors currently open),
# not a seen-set: two sibling from-parquet nodes over the same path are
# not a cycle, so only a node reached from ITSELF is one . The path carries the ancestor VALUES: `=` compares tables by
# identity and structs by recursive CONTENT, which is independent of
# declaration order - a struct rebuilt with the same fields in another
# order is still a revisit. No key is constructed at all: per-node key
# building made the shared-subtree walks superlinear.
# (Reader finding 5 claimed the former (hash ;(keys x)) key was
# layout-SENSITIVE; probed and not reproduced - hash and `=` agree on
# layout - and the key is gone regardless.) These must be MACROS, not
# defn/typed functions: the caller's array is mutated in place, and a typed
# function's register-captured args would swallow that mutation.
(defmacro seen* [path x]
  "Is x one of the currently open ancestors in path? Content equality is
 layout-independent for structs and identity-based for tables, so the path
 holds values and no key is constructed (a structural key per node made the
 shared-subtree walks superlinear)."
  ~(do (var s% false)
       (def xk% ,x)
       (each y% ,path (when (= y% xk%) (set s% true)))
       s%))

(defmacro enter* [path x]
  "Open x as an ancestor: a node reached from itself is a cycle."
  # ONE form: separate top-level strands in a macro body lose effects when
  # a sibling conditional plus an array/push pair meets an empty array
  ~(do
     (when (seen* ,path ,x)
       (err :malformed-tree {:node ,x :why :cyclic-tree}))
     (array/push ,path ,x)
     nil))

(defmacro leave* [path]
  "Close the innermost open ancestor."
  ~(array/pop ,path))

(defn/typed handle-backend {:args [:any] :ret :any}
  [src]
  "The handle backend a source carries: a keyword :backend, a string
:backend (kept as-is - it names a backend that can never be registered,
so selection reports it as unknown), or nil (not a handle, or a handle
without a keyword/string :backend - the tree pass owns that class)."
  (when (or (struct? src) (table? src))
    (def b (get src :backend))
    (when (or (keyword? b) (string? b)) b)))

(defn/typed collect-sources {:args [:any] :ret :tuple}
  [q]
  "Light walk collecting only provenance (backend-bound handles in
from-node and from-parquet-node sources). No validation - selection runs
BEFORE expansion (conflict-before-expansion, property (e)). Nodes are
valid as both structs and mutable tables (contract 1), so the walk
visits any map-like value (dictionary? covers both) - a table-built
tree carries provenance exactly as a struct-built one does. A handle
whose :backend is a STRING is provenance too: it names a backend that
can never be registered, so selection reports :unknown-backend for it instead of silently executing elsewhere. The walk carries
an ancestor path: a node equal to one of its own ancestors is a cyclic
tree and raises the contract class instead of looping (contract 5)."
  (def provs @[])
  (def path @[])
  # a subtree reached twice is walked once: the
  # visited set is keyed by IDENTITY, so a diamond tree costs linear in node
  # count instead of 2^depth. The path still runs the cycle check on entry,
  # so a genuine cycle raises before the memo can hide it.
  (def visited @{})
  (defn walk [t]
    (when (dictionary? t)
      (def id (ident-key t))
      (enter* path t)
      (unless (get visited id)
        (put visited id true)
        (when (= :query (get t :node)) (walk (get t :tree)))
        (when (or (= :from (get t :node)) (= :from-parquet (get t :node)))
          (def src (get t :src))
          (when (handle-backend src)
            (array/push provs (handle-backend src))))
        (walk (get t :input))
        (when (get t :sides) (each s (get t :sides) (walk s)))
        (when (get t :left) (walk (get t :left)))
        (when (get t :right) (walk (get t :right))))
      (leave* path)))
  (walk q)
  (uniq provs))

(defn/typed handle-without-backend? {:args [:any] :ret :boolean}
  [q]
  "Does the tree carry a map-like from-node source naming no usable
backend? Such a source is a handle whose provenance is unknown, which
selection reports as :backend-ambiguous (contract 4.3 v0.5) - a table
or parquet source (a keyword/string) carries no handle provenance and
is not ambiguous. Walks the same surface the provenance walks do."
  (var found false)
  (def path @[])
  (def visited @{})
  (defn walk [t]
    (when (and (dictionary? t) (not found))
      (def id (ident-key t))
      (enter* path t)
      (unless (get visited id)
        (put visited id true)
        (when (= :query (get t :node)) (walk (get t :tree)))
        (when (or (= :from (get t :node)) (= :from-parquet (get t :node)))
          (def src (get t :src))
          (when (and (or (struct? src) (table? src)) (nil? (handle-backend src)))
            (set found true)))
        (when (not found) (walk (get t :input)))
        (when (and (not found) (get t :sides))
          (each s (get t :sides) (walk s)))
        (when (not found) (walk (get t :left)))
        (when (not found) (walk (get t :right))))
      (leave* path)))
  (walk q)
  found)

(defn/typed guard-cross-backend {:args [:any] :ret :nil}
  [q]
  "Composition-time cross-backend guard: a tree whose handle sources
(from-nodes AND from-parquet-nodes) name more than one distinct backend
is a cross-engine query, out of scope by construction (one query, one
backend per execution). Walks the SAME surface collect-sources does
(map-like nodes, identity-set cycle protection), so the guard and
provenance collection never disagree. Parquet nodes without a :src
carry no provenance and stay neutral. The guard walks the WHOLE tree
before deciding: the raise names the last provenance node and ALL
distinct backends seen, sorted - raising at
the second distinct backend could never report a third."
  (def found @[])
  (var last-node nil)
  (def path @[])
  (def visited @{})
  (defn walk [t]
    (when (dictionary? t)
      (def id (ident-key t))
      (enter* path t)
      (unless (get visited id)
        (put visited id true)
        (when (= :query (get t :node)) (walk (get t :tree)))
        (when (or (= :from (get t :node)) (= :from-parquet (get t :node)))
          (def b (handle-backend (get t :src)))
          (when b
            (unless (find |(= b $) found) (array/push found b))
            (set last-node t)))
        (walk (get t :input))
        (when (get t :sides) (each s (get t :sides) (walk s)))
        (when (get t :left) (walk (get t :left)))
        (when (get t :right) (walk (get t :right))))
      (leave* path)))
  (walk q)
  (when (> (length found) 1)
    (err :malformed-tree {:node last-node :why :cross-backend-handles
                          :backends (tuple ;(sort found))}))
  nil)

(defn/typed node-types-of {:args [:any] :ret :tuple}
  [tree]
  "The coverage-manifest node types a tree names: every :node value
plus the matrix-gated lanes derived from expressions (agg and call
operators) and join variants. A :query wrapper anywhere (top level or
nested) is transparent: its tree is walked, the wrapper type never
enters the set (it is not a registrable operator)."
  (def out @[])
  (def seen @{})
  (defn walk [t]
    (when (struct? t)
     (def id (ident-key t))
     (unless (get seen id)
      (put seen id true)
      (def n (get t :node))
      (if (= :query n)
        (walk (get t :tree))
        (do
          (when (and n (not (index-of n out))) (array/push out n))
          (case n
            :join (case (get t :type)
                    :asof (array/push out :asof)
                    :wco (array/push out :wco)
                    :anti (array/push out :join-anti)
                    nil)
            nil)
          (walk (get t :input))
          (when (get t :sides) (each s (get t :sides) (walk s)))
          (when (get t :left) (walk (get t :left)))
          (when (get t :right) (walk (get t :right)))
          (when (= :escape n) (array/push out :escape))))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  (each a (agg-ops-of tree)
    (when (index-of a [:count-distinct :median]) (array/push out a)))
  (each c (expr-calls-of tree)
    (case c
      :idiv (array/push out :expr-idiv)
      :mod (array/push out :expr-mod)
      :in (array/push out :expr-in)
      :not-in (array/push out :expr-not-in)
      nil))
  (uniq out))

(defn/typed freeze-slots {:args [:any] :ret :any} [t]
  "Deep-freeze a MAP-LIKE node's mutable slots into tuples so the tree
value the tree pass validates is the value every later reader sees
(contract 1 inert data: a caller-held array alias can no longer change
an expanded tree). Arrays become tuples; map-likes are rebuilt with
frozen slots (structs whose slots held no array are returned as-is);
tuple elements are frozen recursively. A value reached twice (through
an alias or a cycle) is frozen once: the memo array makes the stop
cheap, and the pre-selection walks raise the cycle class first)."
  (def seen @[])
  (defn deep [x]
    (cond
      (or (struct? x) (table? x))
      (if (index-of x seen) x
        (do
            (array/push seen x)
            (var changed false)
            (def out
              (if (struct? x)
                (struct ;(mapcat (fn [[k v]] (def v* (deep v))
                                   (unless (= v v*) (set changed true))
                                   (if (keyword? k) [k v*] [(string k) v*]))
                                 (pairs x)))
                (do (def tb @{})
                    (eachp [k v] x (put tb k v))
                    tb)))
            (when (table? x)
              (eachp [k v] x (def v* (deep v))
                     (unless (= v v*) (set changed true))
                     (put out k v*)))
            (if changed out x)))
      (indexed? x)
      (if (index-of x seen) (tuple ;x)
        (do (array/push seen x) (tuple ;(map deep x))))
      x))
  (if (or (struct? t) (table? t)) (deep t) t))

(defn/typed expr-columns {:args [:any] :ret :array}
  [e]
  "Column references of an expression subtree as [alias col] pairs. The
qualifier is emitted in ONE form - a string qualifier naming an arm is the
same arm as the keyword spelling, so it is
normalised here, before any match. `(get :b \"t\")` and `(get :b :t)` then
bind to the same source and report the same name; without this the string
form missed every source and surfaced in the unknown-column lane as the
QUALIFIER rather than the column."
  (def out @[])
  (defn norm-alias [a] (if (string? a) (keyword a) a))
  (defn walk-e [e]
    (when (struct? e)
      (when (= :get (get e :expr))
        (array/push out [(norm-alias (get e :alias)) (get e :col)]))
      (when (indexed? (get e :args)) (each a (get e :args) (walk-e a)))
      (walk-e (get e :arg))))
  (walk-e e)
  out)
(defn/typed alias-match {:args [:table :any :any] :ret :boolean} [tab-alias tab a]
  (def stored (get tab-alias tab))
  (if (nil? stored) (or (nil? a) (= false a)) (= stored (or a false))))

(defn/typed join-key-sentinel? {:args [:any] :ret :boolean} [c]
  "Is c a join key-lane sentinel (tree-columns' [nil \"__lkey\" k] /
[nil \"__rkey\" k] rows)? Those rows are lane-local: a join key is not a
column of any source a catalog describes, so the catalog name check skips
them (they used to reach the alias branch and the internal sentinel
surfaced as a user-facing name)."
  (or (= c "__lkey") (= c "__rkey")))

(defn/typed tree-columns {:args [:any] :ret :array}
  [tree]
  "All column references in a tree as [table alias col] triples - the
catalog name-check input. :table is the source the reference binds to:
the source's table name (from alias), the parquet source key (from the
alias, else the path), or nil for a join-side synthetic key (those are
lane-local and skip the catalog). An explicit alias on the reference
narrows the triple to the sources carrying that alias; an unknown alias
is recorded alone so the check can name it. The triple carries the
SOURCE KEY, so the check can scope each reference to its own source's
catalog entry (a source the catalog does not name defers to the engine
)."
  (def out @[])
  (def tab-alias @{})
  (def tab-cat @{})
  # a subtree reached twice by either pass is walked once per identity
  #;
  # the two passes keep SEPARATE memos - they visit different slots
  (def vseen @{})
  (def rseen @{})
  # catalog key -> every binding key naming that source: an unqualified
  # reference binds to all of them, and the check confirms the reference on
  # ANY of the source's keys (a parquet node answers to its path and to its
  # alias, and a catalog may carry either)
  (def key-of @{})
  (defn record-source [tab alias cat-key]
    # `put` with a nil value deletes the key, and a parquet source keyed by
    # its own path carries no alias - false stands in for "no alias"
    (put tab-alias tab (or alias false))
    (put tab-cat tab cat-key)
    (def ks (if (get key-of cat-key) (get key-of cat-key)
                (do (put key-of cat-key @[]) (get key-of cat-key))))
    (unless (index-of tab ks) (array/push ks tab))
    # a parquet node's alias is a catalog source key too (contract 4)
    (when (and alias (not= alias tab))
      (put tab-alias alias alias)
      (put tab-cat alias cat-key)
      (unless (index-of alias ks) (array/push ks alias))))
  # sources are collected in a first full pass: a reference is resolved
  # against the whole tree, not against whatever was recorded before it
  # in the walk order (a select above its input sees its own source)
  (defn walk [t]
    (when (struct? t)
      (def id (ident-key t))
      (unless (get vseen id)
        (put vseen id true)
        (if (= :query (get t :node))
          (walk (get t :tree))
          (do
            (case (get t :node)
              :from (record-source (get t :src) (get t :alias) (get t :src))
              # a parquet source is catalogued under its path OR its alias
              # (contract 4 v0.5); the path is the record's default key
              :from-parquet (record-source (or (get t :alias) (get t :path))
                                           (get t :alias)
                                           (get t :path))
              nil)
            (walk (get t :input))
            (when (get t :sides) (each s (get t :sides) (walk s)))
            (when (get t :left) (walk (get t :left)))
            (when (get t :right) (walk (get t :right)))))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  (defn emit-row [tab a c]
    (array/push out [tab a c (get tab-cat tab)]))
  (defn walk-refs [t]
    (when (struct? t)
      (def id (ident-key t))
      (unless (get rseen id)
        (put rseen id true)
        (if (= :query (get t :node))
          (walk-refs (get t :tree))
          (do
          # the sources on THIS node's own data path: its input (and a query
          # wrapper's tree). An arm node binds to the whole tree, as before.
          (def path-tabs @{})
          # collect-path runs once per node IDENTITY. It had no memo,
          # so every node re-walked its whole subtree and a shared tree cost
          # 2^depth (measured 16/34/111/305 ms at d=10/12/14/16, ~4x per
          # two levels). The subtree's source set is a pure function of the
          # node, so the memo is exact, not an approximation
          (def pseen @{})
          (defn collect-path [s]
            (when (struct? s)
              (def sid (ident-key s))
              (unless (get pseen sid)
                (put pseen sid true)
                (case (get s :node)
                  :from (put path-tabs (get s :src) true)
                  :from-parquet
                  (do (when (get s :path) (put path-tabs (get s :path) true))
                      (when (get s :alias)
                        (put path-tabs (get s :alias) true)
                        (put path-tabs (or (get s :src) (get s :alias)) true)))
                  nil)
                (collect-path (get s :input))
                (collect-path (get s :tree))
                (when (get s :sides) (each x (get s :sides) (collect-path x)))
                (when (get s :left) (collect-path (get s :left)))
                (when (get s :right) (collect-path (get s :right))))))
          (collect-path (get t :input))
          (defn emit [a c]
            # every alias-bearing slot resolves the same way: a pair
            # binds to the sources carrying that alias, an unknown alias
            # is recorded alone (the check names it). An UNQUALIFIED
            # reference binds to the sources on ITS OWN data path: for a
            # join/asof that is the arms; for a selector it is :input alone,
            # never a sibling arm of a join further up (the sibling
            # row named a source the reference never reads)
            (def cand
              (if (or (= :join (get t :node)) (= :asof (get t :node))
                      (= :append (get t :node)))
                (sort (keys tab-alias))
                (sort (keys path-tabs))))
            (def hits (seq [tab :in cand :when (alias-match tab-alias tab a)] tab))
            (if (empty? hits)
              (array/push out [nil a c nil])
              (each tab hits (emit-row tab a c))))
          (defn emit-expr [e]
            (each [a c] (expr-columns e) (emit a c)))
          (when (get t :expr) (emit-expr (get t :expr)))
          (when (struct? (get t :pred)) (emit-expr (get t :pred)))
          (when (get t :keys)
            (each k (get t :keys)
              (if (struct? k) (emit-expr k) (emit nil k))))
          (when (get t :cols)
            (each c (get t :cols)
              (if (struct? c) (emit-expr c) (emit nil c))))
          (when (get t :aggs)
            (each a (if (indexed? (get t :aggs)) (get t :aggs) [])
              (when (struct? a) (emit-expr a))))
          (when (get t :lkeys)
            (each lk (get t :lkeys) (emit-row nil "__lkey" lk)))
          (when (get t :rkeys)
            (each rk (get t :rkeys) (emit-row nil "__rkey" rk)))
          (walk-refs (get t :input))
          (when (get t :sides) (each s (get t :sides) (walk-refs s)))
          (when (get t :left) (walk-refs (get t :left)))
          (when (get t :right) (walk-refs (get t :right)))))))
    (when (indexed? t) (each x t (walk-refs x))))
  (walk-refs tree)
  out)

#==------------------------------------------------------------------------==#
# Catalogue-key normalisation
#==------------------------------------------------------------------------==#
# A catalogue key is a NAME the caller wrote for a source, so it is one name
# in either spelling: a string, a keyword and a symbol key the same entry.
# Column names normalise to the keyword form; the key form is
# the same rule at the key surface (the key SET is the authority, the key
# SPELLING is not). Normalising here means an arm is
# described no matter which form keys it - never that a key reaches an arm
# the record does not name, which stays `catalog-entries`' question.

(defn/typed catalog-key-form {:args [:any] :ret :any}
  [k]
  # The normalised form of a catalogue key: ONE name, one form, so a string,
  # a keyword and a symbol spelling of the same source all answer alike
  # (the same rule at the key surface). The single form is the keyword, which
  # is where column names already normalise, so every comparison in this
  # block is made on it. A non-name key is returned untouched.
  (cond
    (keyword? k) k
    (symbol? k) (keyword k)
    (string? k) (keyword k)
    k))

# Every spelling a catalogue may key one source under: the key as given, its
# normalised form, and both forms with the other TEXT type. A literal map can
# key an entry only on a same-type value, so a normalised miss is retried
# once as text. (A comment, not a docstring: defn/typed reads a multi-line
# longstring as the first body form, not as the docstring.)
(defn/typed catalog-key-variants {:args [:any] :ret :array} [k]
  (def out @[])
  (defn add [x] (when (and x (not (index-of x out))) (array/push out x)))
  (add k)
  (def nk (catalog-key-form k))
  (add nk)
  (when (or (string? k) (keyword? k) (symbol? k))
    (def t (string nk))
    (add t)
    (add (keyword t))
    (add (symbol t)))
  out)

# the entry carries a writer value. The test is PRESENCE, and
# nil is absent (an entry built without the key, or with :writer nil, carries
# nothing to read).
(defn/typed writer-present? {:args [:any] :ret :boolean} [e]
  (not (nil? (get e :writer))))

# FIELDLESS IS A VALUE TEST. An entry is fieldless exactly when
# its writer value is not ONE record name - absent, empty, a list, a number or
# a name resolving to none. A fieldless entry carries no testimony, so item 3
# never reaches it and it keeps the 03fc1ec walk exactly. Identity never
# resolves unless the arm itself does, so an unresolved value reads fieldless.
(defn/typed writer-fieldless? {:args [:any :any] :ret :boolean} [arm-rec entry-rec]
  (or (nil? arm-rec) (nil? entry-rec)))

# the WRITER of a writer-bearing entry, resolved to a record
# through the same identity machinery as the arm's own record - never from
# the catalogue (the circularity bar). Keyed form first: the
# value names a record exactly when identity names one for it.
(defn/typed entry-writer-record {:args [:any :any] :ret :any} [id-map e]
  (def w (get e :writer))
  (when (and (dictionary? id-map) (or (string? w) (keyword? w) (symbol? w)))
    (var owners nil)
    (each v (catalog-key-variants w)
      (when (nil? owners)
        (def os (let [x (get id-map v)] (and (dictionary? x) (get x :owners))))
        (when (and (indexed? os) (= 1 (length os))) (set owners os))))
    (when (nil? owners)
      (def ao (get id-map :alias-owner))
      (when (dictionary? ao)
        (each v (catalog-key-variants w)
          (when (nil? owners)
            (def os (get ao v))
            (when (and (indexed? os) (= 1 (length os))) (set owners os))))))
    (when owners (owners 0))))

# The admission half of the writer conditions, for an entry that reached
# the arm through the alias spelling: `source-columns`' own-key set (the one the
# marking pass uses) carries only the binding key, so an alias-reached
# writer-bearing entry would read a two-key catalogue as blocked. This is the
# SAME test stated over the record's full spelling set - no subtraction, no
# writer term (erratum C narrowed: content decides the block, not the writer).
(defn/typed colset-key {:args [:any] :ret :string}
  [cs]
  "Canonical key for a column LIST as a SET (list order and
  duplicates do not matter)."
  (string/join (sort (map string cs)) "|"))

(defn/typed record-blocked? {:args [:any :any :any] :ret :boolean}
  [catalog record-keys cs]
  (when (and catalog cs)
    (def want (colset-key cs))
    (var hit false)
    (eachp [ek e] catalog
      (when (and (not hit) (not (get record-keys (catalog-key-form ek))))
        (def acs (get e :columns))
        (when (and acs (= want (colset-key acs))) (set hit true))))
    hit))

# The entry a catalogue holds under a key, in any of the key's spellings;
# nil when none. The ONLY catalogue read in the resolver, so no site below
# chooses a key form.
(defn/typed catalog-entry-at {:args [:any :any] :ret :any} [catalog k]
  (when catalog
    (var hit nil)
    (each v (catalog-key-variants k)
      (when (nil? hit)
        (def e (get catalog v))
        (when e (set hit e))))
    hit))

(defn/typed source-identity-map {:args [:any] :ret :table}
  [tree]
  "Binding spelling -> {:owners [<record id>...] :canons {<id> <canon>}} for
every source of a tree, keyed in every spelling `catalog-key-variants` makes
of the source's name. ADDITIVE to `source-catalog-key`, which keeps its
spelling-only shape for the readers that never ask whose entry it is.

The identity is the SOURCE RECORD's position in the walk, taken only by a
source node so an operator between two sources cannot renumber them. The
map is keyed by RECORD PATH: an alias is a
spelling a caller may key an entry under, never an ownership binding - if
alias text owned keys one key could describe any arm. Two
records may share a path text (the same file under two aliases): the
spelling then lists both owners, and a reader that must name exactly one
record finds none. A key matching no path is FOREIGN to every record.

Why not content: `=` is CONTENT equality, so a value built from a record's
keys answers for two records that share a text."
  (def out @{})
  (def seen @{})
  (var record-count 0)
  # an alias is not an OWNERSHIP binding (it never puts
  # the alias text into the ownership map), but it is still the key the
  # record is ADDRESSED by in the tree, so the map carries
  # a separate alias -> record lookup for the resolver to find a record
  # from a binding key. It grants the arm nothing the path test did not.
  (def alias-owner @{})
  (defn bind [k src canon]
    (when (not (nil? k))
      (each f (catalog-key-variants k)
        (def cur (get out f))
        (cond
          # `:canon` is the binding spelling's OWN source reference: the
          # record's path, or the table name for a from source ). Two spellings of one record share it; a spelling
          # of a DIFFERENT record never does, which is the identity the
          # catalogue test compares
          (nil? cur) (put out f {:owners @[src] :canons @{src canon} :canon canon})
          (not (index-of src (get cur :owners)))
          (do (array/push (get cur :owners) src)
              (put (get cur :canons) src canon)))))
    nil)
  (defn walk [t]
    (when (struct? t)
      (def id (ident-key t))
      (unless (get seen id)
        (put seen id true)
        (if (= :query (get t :node))
          (walk (get t :tree))
          (do
            (var who nil)
            (case (get t :node)
              :from (do (set who (++ record-count))
                        (bind (get t :src) who (get t :src)))
              :from-parquet (do (set who (++ record-count))
                                # The id map binds PATH ->
                                # record only. Alias text is a SPELLING the
                                # caller may key an entry under, not an
                                # ownership binding: if alias text owned
                                # keys, one key could describe any arm,
                                # A key
                                # naming no source by RECORD PATH is foreign.
                                (bind (get t :path) who (get t :path))
                                (when-let [al (get t :alias)]
                                  (each f (catalog-key-variants al)
                                    (def cur (get alias-owner f))
                                    (put alias-owner f
                                         (if (and (indexed? cur)
                                                  (not (index-of who cur)))
                                           (do (array/push cur who) cur)
                                           (if (indexed? cur) cur @[who]))))))
              nil)
            (walk (get t :input))
            (when (get t :sides) (each s (get t :sides) (walk s)))
            (when (get t :left) (walk (get t :left)))
            (when (get t :right) (walk (get t :right)))))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  (put out :alias-owner alias-owner)
  out)

(defn/typed source-of-key {:args [:any :any] :ret :any}
  [id-map k]
  "Which RECORD a catalogue key names: the identity its first spelling binds
to exactly one record. nil when no spelling names a record - either because
no record carries the text, or because TWO do: a text two sources share
cannot say which one a catalogue entry was written for."
  (when (and (dictionary? id-map) (or (string? k) (keyword? k) (symbol? k)))
    (var out nil)
    (def vs (catalog-key-variants k))
    (var i 0)
    (while (and (nil? out) (< i (length vs)))
      (def e (get id-map (vs i)))
      (def os (and (dictionary? e) (get e :owners)))
      (when (and (indexed? os) (= 1 (length os))) (set out (os 0)))
      (++ i))
    # a PATH spelling names a record outright. An ALIAS
    # spelling reaches a record only as the key that record is ADDRESSED by
    # in this tree - it confers no ownership, so it is
    # consulted only when no path matched, and only to identify the record
    # whose own path then decides every table question.
    (when (nil? out)
      (def ao (get id-map :alias-owner))
      (when (dictionary? ao)
        (var j 0)
        (while (and (nil? out) (< j (length vs)))
          (def os (get ao (vs j)))
          (when (and (indexed? os) (= 1 (length os))) (set out (os 0)))
          (++ j))))
    out))

(defn/typed binding-source {:args [:any :any] :ret :any}
  [id-map v]
  "The SOURCE REFERENCE a binding spelling stands for: the record path a
parquet arm is catalogued under, or a from source's table name. Both the
spelling's own reference and its record's canonical one qualify, so an alias
and a path of one arm answer the same while a sibling's text never does. nil
when the spelling binds to no record."
  (when (and (dictionary? id-map) (or (string? v) (keyword? v) (symbol? v)))
    (var out nil)
    (def vs (catalog-key-variants v))
    (var i 0)
    (while (and (nil? out) (< i (length vs)))
      (def f (vs i))
      (def e (get id-map f))
      (def os (and (dictionary? e) (get e :owners)))
      (when (and (indexed? os) (= 1 (length os)))
        (set out (or (get e :canon) (get (get e :canons) (os 0)) f)))
      (++ i))
    out))

(defn/typed same-source? {:args [:any :any :any] :ret :boolean}
  [id-map arm-src v]
  "Does catalogue key `v` name the SAME source record as `arm-src`, the arm's
own reference taken from the ARM NODE - `:path` for a parquet arm, `:src` for
a from arm? The comparison is tree state against the
identity map, so it cannot be supplied by the catalogue it judges: reading
the entry's own field would let a caller's entry testify to its own
admissibility, and no entry field carries a source anyway.
Cross kind never matches, because a table name and a file path are different
references even when the text is identical (node kind is part of the identity). A spelling binding to no single record, or an arm with no
reference of its own, cannot be refuted and therefore passes: absence is not
a foreign claim."
  (if (nil? arm-src)
    true
    (if-let [v-src (binding-source id-map v)] (= arm-src v-src) true)))

(defn/typed source-record {:args [:table :any] :ret :any}
  [id-map k]
  "The arm record a catalogue key names, rebuilt from the record's own canon.
The NODE KIND follows the identity map's own resolution, the only record-based
definition available: a key whose canon is a parquet PATH names a from-parquet
arm; a key with no parquet path names a from source, whose :path is its canon
so the shared-block guard recognises the arm's own entry under the catalogue's
spelling of it. nil when the key names no single
record. Sites that hold only a key hand this to the resolver so the judgement
is made on the RECORD, not the spelling."
  (def s (source-of-key id-map k))
  (var out nil)
  (when (not (nil? s))
    (eachp [ek e] id-map
      (when (and (nil? out) (not= :alias-owner ek) (dictionary? e)
                 (index-of s (get e :owners)))
        (def canon (get (get e :canons) s))
        (set out (if canon
                   {:node :from-parquet :path canon :alias ek}
                   # a from arm: the canon IS its source, and carrying it as
                   # :path lets the path-gated shared-block guard run for a
                   # rebuilt record exactly as it does for the real tree node
                   {:node :from :src (or canon k) :path (or canon k)}))))
    (when (nil? out)
      (set out {:node :from :src k :path k})))
  out)

(defn/typed source-owner-keys {:args [:table :any] :ret :table}
  [id-map s]
  "Every spelling bound to ONE record identity `s`, as a set. This is the
own-key set the shared-block guard reads: it must hold a source's own
spellings (so an alias and a path never look like two sources) and nothing
else (so an alien key carrying the same list still reads as a block)."
  (def out @{})
  (when (not (nil? s))
    (eachp [ek e] id-map
      # `:alias-owner` is a lookup table, not an ownership entry : alias text is never one of a record's own keys
      (when (and (not= :alias-owner ek) (dictionary? e)
                 (index-of s (get e :owners)))
        (each v (catalog-key-variants ek) (put out v true)))))
  out)

(defn/typed source-catalog-key {:args [:any] :ret :table}
  [tree]
  "Binding key -> catalog source key for every source of a tree. A from
source is keyed by its table name; a from-parquet source by its path and
- when it carries an :alias - by that alias, both resolving to the path
(contract 4 v0.5: catalogued under the from-parquet path, or the node's
:alias when it carries one). The catalog name check reads this to scope a
reference to ITS OWN source: a
binding key the catalog does not name leaves the engine as the only
validator, as for an absent catalog. The map is only the key -> source
half of the lookup: `catalog-entries` decides WHICH entries a source
answers to, so no site reads this map as a single key."
  (def out @{})
  (def seen @{})
  (defn walk [t]
    (when (struct? t)
     (def id (ident-key t))
     (unless (get seen id)
      (put seen id true)
      (if (= :query (get t :node))
        (walk (get t :tree))
        (do
          (case (get t :node)
            # a source's keys enter the map in NORMALISED form,
            # so a key a site reads from this map already answers for its
            # form; the catalogue lookup still retries the raw text form
            :from (put out (catalog-key-form (get t :src)) (get t :src))
            :from-parquet (do (put out (catalog-key-form (get t :path)) (get t :path))
                              (when (get t :alias)
                                (put out (catalog-key-form (get t :alias)) (get t :path))))
            nil)
          (walk (get t :input))
          (when (get t :sides) (each s (get t :sides) (walk s)))
          (when (get t :left) (walk (get t :left)))
          (when (get t :right) (walk (get t :right)))))))
    (when (indexed? t) (each x t (walk x))))
  (walk tree)
  out)

#==------------------------------------------------------------------------==#
# The catalogue-key resolver
#==------------------------------------------------------------------------==#
# EVERY catalogue lookup in this module goes through the two functions
# below. The contract's catalogue rule is one
# sentence: the caller's catalogue decides UNION MEMBERSHIP, which columns
# an arm contributes, never a verdict. A single-key lookup (alias only, or
# path only) lets the key the caller chose decide a verdict. The
# rule is therefore expressed ONCE, as the set of entries a source can
# answer to, and every site reads that set instead of choosing a key.
# `source-catalog-key` maps each BINDING key to the source's canonical
# key; `catalog-entries` returns every entry the source answers to.

(defn/typed record-columns {:args [:any] :ret :any}
  [arm]
  "The columns the ARM RECORD itself sources, as a set of normalised names.
nil when the record states none, which is not the same as an empty source: a
record with no known schema constrains nothing, so the content test cannot
run. Read from the record only - never from a catalogue
entry, or the test would confirm the very claim it checks."
  (when (dictionary? arm)
    (def raw (or (get arm :columns) (get arm :schema)))
    (when (and raw (indexed? raw))
      (def out @{})
      (each c raw
        (def nm (if (struct? c) (or (get c :col) (get c :as) (get c :alias)) c))
        (when nm (put out (string (keyword nm)) true)))
      out)))

(defn/typed consistent? {:args [:any :any] :ret :boolean}
  [cols claimed]
  "Does an entry's column list stay within the arm's own record-sourced
columns? An entry claiming a name the arm's source does not carry describes
ANOTHER source (the `foreign` disposition) and contributes
nothing. True when either side is unknown: an unconstrained record or an
entry with no list makes no claim to refute."
  (if (or (nil? cols) (nil? claimed) (not (indexed? claimed)))
    true
    (nil? (find |(not (get cols (string (keyword $)))) claimed))))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn catalog-entry-keys
  [catalog key-of k path &opt id-map]
  "The ADMITTED catalogue keys for a source, in resolution order - the
canonical key, the binding key and the parquet node's other path/alias
spelling - after the identity and PATH tests. The one
authority on admissibility, so a reader that must pick ONE spelling
(`source-columns`' preference) cannot reach past the tests. Keys are
returned whether or not the catalogue holds an entry under each."
  (def canon (get key-of k))
  (var ks @[])
  # every spelling of every key the source answers to: the
  # canonical key, the binding key and the other path/alias spelling, each
  # in the forms a catalogue may hold it under
  (each x [canon k path]
    (when x
      (each v (catalog-key-variants x)
        (when (not (index-of v ks)) (array/push ks v)))))
  # a spelling two records share is not this
  # source's key. With the identity map in hand, a spelling bound to a
  # record other than this one is dropped, so a sibling's entry never
  # answers for this arm. Without the map the set is exactly as before.
  (when (dictionary? id-map)
    # the arm's record is identified by its PATH, never by the spelling a
    # caller keyed an entry under: `k` may be an alias,
    # so it cannot testify to ownership
    (def s (source-of-key id-map (or path k)))
    (defn owners-of [v]
      (def e (get id-map v))
      (def os (and (dictionary? e) (get e :owners)))
      (if (indexed? os) os @[]))
    # a spelling bound to exactly one record and NOT this one belongs to a
    # sibling: it must never answer for this arm
    (defn alien? [v]
      (def os (owners-of v))
      (and (= 1 (length os)) (not (index-of (os 0) (if (nil? s) @[] @[s])))))
    # a spelling two records share cannot say whose entry it is, so it is
    # not this source's key either: the text names a
    # SIBLING as much as it names the arm. Without an identity owner for
    # the arm the arm cannot claim a shared spelling at all.
    (defn ambiguous? [v] (> (length (owners-of v)) 1))
    # An arm's alias spellings enter
    # the candidate set WITHOUT a path test - alias text is not ownership, but
    # it does nominate. Whether the entry then describes THIS arm is decided
    # by SOURCE IDENTITY: the entry's own source reference against the one
    # each spelling binds to. Alias text as OWNERSHIP is the refuted reading;
    # alias text as a NOMINATION reaches only records the text is bound to.
    (def own-alias @{})
    (when-let [al (get id-map :alias-owner)]
      (when (dictionary? al)
        (eachp [ak aos] al
          (when (and (indexed? aos) (= 1 (length aos)) (= s (aos 0)))
            (each v (catalog-key-variants ak) (put own-alias v true))))))
    # ARM-SCOPED attribution. The arm's source comes from the arm
    # record (`arm-src`, below), never from the catalogue, so a key is
    # admissible only when it resolves to THAT source.
    # Taking the entry's source instead is inert: no entry field carries one, and
    # reading the catalogue would be circular regardless. This is the
    # discriminator for both collision shapes - alias text and a second
    # spelling of a foreign record (a decoy). Column content is not a
    # discriminator: arm records carry no schema, so a content
    # test has no right-hand operand and is inert by construction.
    # The arm's own reference, by node kind: identity is not text. `when`, not
    # `and`: a non-string last operand would yield `false`, and `false` is not
    # `nil`, so it would be compared as a source instead of read as "no
    # reference".
    (def arm-src (or (when (string? path) path) (when (string? k) k)))
    (defn describes-arm? [v] (same-source? id-map arm-src v))
    (if (nil? s)
      # Conservative edge: an arm whose own
      # source cannot be resolved is not described by any entry
      (set ks @[])
      (set ks (filter (fn [v]
                        (and (not (alien? v))
                             (not (ambiguous? v))
                             (or (get (source-owner-keys id-map s) v)
                                 (get own-alias v))
                             (describes-arm? v)))
                      ks))))
  ks)

# The catalogue entries a source answers to: the ADMITTED keys of
# `catalog-entry-keys`, each resolved to its entry. Empty when the catalogue
# does not name the source. A caller who catalogued the arm under its alias
# and one who catalogued it under its path get the same answer from the same
# entry.
# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn catalog-entries
  [catalog key-of k path &opt id-map]
  (def out @[])
  (each x (catalog-entry-keys catalog key-of k path id-map)
    (when-let [e (catalog-entry-at catalog x)]
      (unless (index-of e out) (array/push out e))))
  out)

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn source-columns
  [catalog key-of k path &opt id-map]
  "The UNION of the column lists every entry a source answers to, as an
ORDERED array of keyword names (first-seen order, duplicates dropped); nil
when no entry describes the source's columns. Union, not first hit: an
entry keyed under the path and one keyed under the alias say the same thing
about the arm, and neither key the caller chose may decide what the other
entry already stated. The order is the entry's own column order so an
append side keeps the position it was catalogued with.

A PARQUET arm (path non-nil) whose entry list is ALSO carried by an entry
that is not another key of the same source is described only by a shared
metadata block and stays undescribed: such a block says nothing about the
file's schema. Reading it would let one catalogue entry
flip a reference verdict, which the catalogue-membership rule forbids; the arm is unnamed,
so the lanes defer instead of refusing.

An entry carrying a WRITER field (:writer) is caller
authorship testimony and takes the identity-scoped admission instead: on a PARQUET arm it is admitted only when its
writer resolves to this record AND it sits under one of the record's own
spellings AND no entry under an ALIEN key carries its list. The block
rule is CONTENT (erratum C): a list carried under an alien key silences
every entry carrying that list, writer-bearing or not - the writer
decides nothing about the block set. Entries whose writer names no
single record are FIELDLESS (item 2, a value test) and keep the
03fc1ec walk exactly; a pathless (from-source) arm does not consult the
field (that lane is unmodelled)."
  (var ks nil)
  (def entries (catalog-entries catalog key-of k path id-map))
  # an entry's list is a SHARED BLOCK when an entry that is NOT another key
  # of this same source lists the identical columns: only then does the list
  # say nothing about this arm. Two keys of ONE arm carrying the same list
  # are that arm being catalogued twice (the correct case), not a block
  # borrowed from a sibling
  (def own-keys @{})
  (each x [k path (get key-of k)]
    (when (and x (not (index-of (catalog-key-form x) (keys own-keys))))
      (put own-keys (catalog-key-form x) true)))
  # widen the own-key set to EVERY spelling of this source
  # RECORD, so an alias and a path of one arm never read as two sources.
  # Widening by identity is what keeps the genuine block detected: an alien
  # key is not bound to this record, so it stays outside the set and its
  # identical list still sets `others`. Without an identity map
  # (a caller that passed none) the set stays exactly as before.
  (when (dictionary? id-map)
    (def s (source-of-key id-map k))
    (each f (keys (source-owner-keys id-map s)) (put own-keys f true)))
  (def others @{})
  # The the arm's RECORD identity, resolved from the arm node (path or
  # binding key) exactly as `catalog-entry-keys` resolves it - never from the
  # catalogue, which the circularity bar forbids. The writer
  # field names this record through the same identity machinery, in any
  # spelling (path or alias); a writer naming no single record is FIELDLESS
  # (item 2), not foreign. Without an identity map or an arm record, identity
  # scoping is undecidable and a carrying entry contributes nothing - absence
  # of testimony is not a foreign claim, but it is not an own one either.
  (def arm-rec (when (dictionary? id-map) (source-of-key id-map (or path k))))
  (defn writer-is-arm? [e]
    (and (not (nil? arm-rec))
         (= arm-rec (entry-writer-record id-map e))))
  (when (and path catalog)
    # the content criterion
    # governs this marking pass - a list carried under a key alien to this
    # record marks a block whether the alien entry carries a writer or not.
    # It does not alter the admission condition: every entry, fieldless or
    # not, is admitted only where its list is not in this set.
    (eachp [ek e] catalog
      (def cs (get e :columns))
      (when (and cs (not (get own-keys (catalog-key-form ek))))
        (put others (colset-key cs) true))))
  # every entry the source
  # answers to CONTRIBUTES its list. Before this an entry chosen by key order
  # prescribed the row alone, so the spelling the caller wrote an entry under
  # decided which of the arm's own lists reached the serve - the form-swap
  # flip the union rule forbids: "the entries
  # are UNIONED, and the catalogue does not decide column order or column
  # membership".
  #
  # `others` (above) is unchanged and still runs first: a list an ALIEN key
  # also carries is a copied metadata block, and such an entry is inert
  # whichever entry count reaches it.
  (defn usable? [e]
    (def cs (get e :columns))
    (or (nil? path) (nil? cs)
        (not (get others (colset-key cs)))))
  (each e entries
    (def cs (get e :columns))
    # The three writer conditions as one letter: a writer-bearing
    # entry on a parquet arm is admitted only when (i) its writer is this
    # record, (ii) it reached the arm through one of the record's own
    # spellings, and (iii) no alien entry carries its list. Items (ii) and
    # (iii) are item 2's key scoping and block rule, restated (erratum B).
    # (iii) is ONE condition for every entry: the list must be absent from
    # the alien-key set. `usable?` answers it over the
    # binding key; `record-blocked?` is the same test over the record's whole
    # spelling set, the one the marking pass above uses.
    # An entry whose writer names no record is FIELDLESS (item 2) and keeps
    # the 03fc1ec usable? walk exactly.
    (def standalone
      (cond
        (not cs) false
        (and path (writer-present? e)
             (not (writer-fieldless? arm-rec (entry-writer-record id-map e))))
        (and (writer-is-arm? e)
             (or (usable? e)
                 (and (dictionary? id-map)
                      (not (record-blocked? catalog
                                             (source-owner-keys id-map arm-rec)
                                             cs)))))
        true (usable? e)))
    (when (or standalone (and (nil? path) (nil? cs)))
      (each c (or cs @[])
        (set ks (or ks @[]))
        (def nm (keyword c))
        (unless (index-of nm ks) (array/push ks nm)))))
  ks)

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn source-catalogued? {:args [:any :table :any :any :any] :ret :any}
  [catalog key-of k path &opt id-map]
  "The columns the catalogue DESCRIBES this source with, or nil when no
entry describes it. Nil is the `undescribed` state: an entry
that describes nothing - an irrelevant path, a shared block, a closed-wall
writer-other entry - is not a description, so catalogue membership never
moves a verdict from defer to refuse. The verdict lanes judge on THIS
answer, never on the presence of an entry. Shared-block and identity rules
are `source-columns`' own, so admission and the verdict lanes cannot
disagree about what describes an arm."
  (source-columns catalog key-of k path id-map))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn sourced-cols
  [catalog key-of tree &opt id-map]
  "The ROW of STORED source columns: the union of what `source-columns`
  describes each of the tree's own source arms with. Nil when the tree
  carries no source arm, or when ANY arm is undescribed in this lane.

Deliberately not `output-columns`: that row adds each select's projection,
and a projection is the reference the gate is judging, so it cannot be the
witness. An undescribed arm is not an empty one - a nil answer defers
which is why the select gate (expand-tree's sixth term) answers a
passthrough above an arm nobody described with a deferral ).

R2b (D1): no longer the select gate's witness - that gate now walks to the
published row (`projectionRefusalIsPublished`), because the source row is
not the boundary a declare-nothing select holds. Retained for callers
that need the stored-source row itself."
  (def arms (filter |(and (dictionary? $)
                          (or (= :from (get $ :node))
                              (= :from-parquet (get $ :node))))
                    (tree-columns tree)))
  (when (> (length arms) 0)
    (var out nil)
    (var ok true)
    (each a arms
      (def ks
        (if (= :from (get a :node))
          (source-catalogued? catalog key-of (get a :src) nil id-map)
          (source-catalogued? catalog key-of
                               (or (get a :alias) (get a :path))
                               (get a :path) id-map)))
      (if (nil? ks)
        (set ok false)
        (each c ks
          (set out (or out @[]))
          (unless (index-of c out) (array/push out c)))))
    (when ok out)))

(defn/typed expr-name {:args [:any] :ret :string} [e]
  "The deterministic aggregate output name: agg_col for column args
(the group node's output-column naming convention, both backends;
renamed outputs stay the per-backend P14 lane - this is composition
mechanics, not a user rename)."
  (string (get e :agg) "_"
          (if (and (struct? (get e :arg)) (= :get (get (get e :arg) :expr)))
            (string (get (get e :arg) :col))
            "0")))

(defn/typed unknown-column!
  {:args [:any] :ret :any}
  [name]
  "Raise :unknown-column naming the column in ONE form: a string entry and a keyword entry name the same column, so the
error always reports a keyword. Before the fix the same defect carried
\"q\" from a string join key and :q from a keyword key."
  (err :unknown-column {:name (if (string? name) (keyword name) name)}))

(defn/typed unnamed-arm? {:args [:any] :ret :boolean} [a]
  "Is this node a parquet arm the engine must read to know?"
  # unresolvable by construction. NOT a catalog
  # question (a caller-supplied catalogue entry alone once flipped five
  # verdicts)
  (and (dictionary? a) (= :from-parquet (get a :node))))

(defn/typed catalogue-rows {:args [:any] :ret :any} [catalog]
  "Every column list the caller supplied, for any key."
  (when catalog
    (apply array/concat @[] (map |(or (get $ :columns) @[]) (values catalog)))))

(defn/typed arm-keys {:args [:any] :ret :table}
  [a]
  "The keys an arm answers to, derived from the ARM RECORD alone ). A from source answers to its table name; a from-parquet arm
 to its path and, when it carries one, its alias. Every entry is
 {binding-key, canonical-key}: a caller may address the arm by either
 spelling, and both spellings resolve to the same canon.

 The record is the identity source: NOTHING here reads a catalogue. Before this helper four sites each wrote `(or (get a :alias) (get a :path))` by hand,
 so the arm's key set was restated at every consumer and a divergent copy
 was invisible to the model. No site may hold its own key logic; a consumer
 that needs an arm's spelling calls this."
  (def out @{})
  (when (dictionary? a)
    (case (get a :node)
      :from (when-let [s (get a :src)] (put out s s))
      :from-parquet (do
                      (when-let [p (get a :path)] (put out p p))
                      (when-let [al (get a :alias)] (put out al (get a :path))))
      nil))
  out)

(defn/typed arm-path-of {:args [:any :any] :ret :any}
  [key-of k]
  "The parquet PATH a catalogue key names, from the key map the arm record
 built. A path names itself; an alias names the path it redirects to. The
 key map is the arm record's own product (`source-catalog-key`), so this
 reads no catalogue."
  (when (dictionary? key-of) (get key-of k)))

(defn/typed arm-binding-key {:args [:any] :ret :any}
  [a]
  "The arm's default binding key: its alias when it has one, otherwise its
 path (parquet) or source (from). This is the key an arm is ADDRESSED by
 when no other spelling is in play - a naming default, never a resolution
 decision: the resolver reads every key `arm-keys` gives, so the choice of
 default cannot change a verdict."
  (when (dictionary? a)
    (or (get a :alias) (get a :path) (get a :src))))

(defn/typed arm-resolvable* {:args [:any :any :table] :ret :any}
  [a catalog key-of]
  # a caller who catalogued THIS arm under the key it is addressed by
  # has told us its columns; that is resolvability, whatever else the
  # catalog holds. The catalog never promotes an arm nothing names
  (cond
    (not (dictionary? a)) true
    (not (unnamed-arm? a)) true
    true
    (let [cols (seq [e :in (apply array/concat
                                  @[] (map |(catalog-entries catalog key-of $ nil)
                                           (keys (arm-keys a))))
                     :let [cs (get e :columns)]
                     :when (and cs (> (length cs) 0))]
                 cs)]
      (> (length cols) 0))))

(defn/typed arm-resolvable? {:args [:any :any :any] :ret :boolean} [a catalog key-of]
  "Could the catalog tell us this arm's own columns?"
  # "unnamed" is arm
  # RESOLVABILITY, never catalog presence. A from-parquet arm is
  # resolvable only where the catalog names it AND its entry's column
  # list stands on its own - at least one name no other entry also
  # lists. A caller who catalogues its parquet aliases copies a shared
  # metadata block into several entries (the r6 baseline: [:a :b] sits
  # in BOTH :t and the alias), and such an entry says nothing about the
  # file's schema. Cataloguing the alias therefore adds known columns
  # without naming the arm
  # the helper is the answer. A (not (nil? ...)) wrapper
  # here read the BOOLEAN `false` as "present", so every arm was resolvable
  # and the whole unnamed-by-resolvability ruling was dead code
  (arm-resolvable* a catalog key-of))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn output-columns-raw {:args [:any :any :any :table :any] :ret :any} [tree catalog memo key-of &opt id-map]
  "Best-effort output column names of a tree, given a catalog; nil
when not determinable (catalog absent for its base table). Used by
the append alignment check (position-aligned columns) and by the
catalog name check's computed-columns lane."
  (cond
    (not (struct? tree)) nil
    (= :query (get tree :node)) (output-columns-raw (get tree :tree) catalog memo key-of id-map)
    (= :select (get tree :node))
      # an ABSENT :cols is an absent
      # declaration, never a declared-empty projection. Reporting () made
      # the pass-through boundary lie: the node hands its input's row on,
      # so that row is its output (the deferral itself is the lane's
      # business, not this function's)
      (if (empty? (get tree :cols))
        (output-columns-raw (get tree :input) catalog memo key-of id-map)
        # a select entry's OUTPUT name: its :as/:alias when it computes
        # one, otherwise the column it re-exposes. An explicit :as RENAMES
        # the entry in the output row, so it wins
        # over the underlying :col. On a :get, :alias is the SOURCE
        # QUALIFIER, never a rename, so it must not win there.
        (tuple ;(map (fn [c]
                       (if (struct? c)
                         (do
                           # :as is a NAME in either
                           # form. A string entry reported ("money") where
                           # the keyword form reported (:money), so one tree
                           # had two different output rows. One form only.
                           (def nm (if (= :get (get c :expr))
                                     (or (get c :as) (get c :col) (get c :alias))
                                     (or (get c :as) (get c :alias))))
                           (if (string? nm) (keyword nm) nm))
                         # a BARE
                         # entry is a name in either spelling. It was handed
                         # through untouched, so ("a") was published for a
                         # string entry where (:a) was published for the
                         # keyword one - two output rows for one name
                         (if (string? c) (keyword c) c)))
                    (get tree :cols))))
    (= :group (get tree :node))
    (tuple ;(map (fn [k] (if (struct? k) (get k :col) (keyword k))) (get tree :keys))
           ;(map |(symbol (expr-name $)) (get tree :aggs)))
    (or (= :from (get tree :node)))
    (let [tab (if (keyword? (get tree :src)) (get tree :src)
                   (when (string? (get tree :src)) (keyword (get tree :src))))
          ks (source-columns catalog key-of tab nil id-map)]
      (when ks (tuple ;ks)))
    (= :from-parquet (get tree :node))
    # G1: a parquet arm's columns are the catalogue's, by BOTH
    # keys. The bare-source lane used to report nil here, so every source
    # lane over an alias-less arm was undeterminable whichever entry named
    # it - and the two-key sites below never ran
    (let [a tree
          ks (source-columns catalog key-of (arm-binding-key a)
                             (get (arm-keys a) (arm-binding-key a)) id-map)]
      (when ks (tuple ;ks)))
    # a join carries :left/:right; an append carries :sides, and its
    # alignment is positional, so the union is the best-effort answer
    (get tree :sides)
    (do
      (def ss (get tree :sides))
      (def cs (map |(output-columns-raw $ catalog memo key-of id-map) ss))
      (var known true)
      (each c cs (when (nil? c) (set known false)))
      (when (and (> (length cs) 0) known)
        (tuple ;(mapcat identity cs))))
    (get tree :input) (output-columns-raw (get tree :input) catalog memo key-of id-map)
    # a join REPOSITIONS its arms, so its row is the UNION of both outputs.
    # An arm whose columns are unknown makes the union unknown:
    # the catalogued arm alone is not the join's row, and
    # publishing it refused an in-scope column of the other arm.
    # an arm that is a from-parquet SOURCE reads its
    # columns from the catalog, which names it under its path or its alias
    # (contract 4 v0.5). Without that the join was undeterminable and the
    # selector above it silently lost the row's :columns. Only the join lane
    # reads it: the bare-source and append lanes keep their documented deferral.
    (get tree :left)
    (let [parq-cols (fn [a]
                      (if (and (struct? a) (= :from-parquet (get a :node)))
                        # a parquet arm
                        # answers to EVERY key it can be catalogued under;
                        # the shared resolver is the one place that decides
                        # which those are
                        (let [ks (source-columns catalog key-of
                                                 (arm-binding-key a)
                                                 (get (arm-keys a) (arm-binding-key a))
                                                 id-map)]
                          (when ks (tuple ;ks)))
                        (output-columns-raw a catalog memo key-of id-map)))
          # An arm whose lane row is nil
          # is UNDECIDABLE, not absent, when an id-free read still
          # describes its record under its own path spelling - the arm's
          # own measured columns enter the join's row with attribution
          # withheld (the per-arm shared-block subtraction at
          # source-columns is exactly what no single arm can pass on the
          # same-path pair; the nil path argument and source-columns are
          # untouched). A record no id-free read describes is
          # READ-FAILED: the arm stays nil and the join keeps today's
          # open deferral (the open row).
          own-cols (fn [a]
                     (def pk (if (= :from-parquet (get a :node))
                               (get a :path)
                               (get a :src)))
                     (when-let [base (source-columns catalog key-of pk nil nil)]
                       (if (= :from-parquet (get a :node))
                         (or (source-columns catalog key-of (arm-binding-key a)
                                             nil nil)
                             base)
                         base)))
          # the id-free read is the same-path license, not a
          # general fallback. Where the arm's own spelling carries WRITER
          # testimony the identity-aware read refuses for an admission
          # reason (foreign writer or content block); the id-free read would
          # re-admit that entry, so the arm stays nil. Fieldless blocking
          # (C4's mutual-copy shape) keeps the id-free read unchanged.
          own-writer-present? (fn [a]
                                (when (= :from-parquet (get a :node))
                                  (def bk (arm-binding-key a))
                                  (def path (get (arm-keys a) bk))
                                  (var hit false)
                                  (each e (catalog-entries catalog key-of bk path id-map)
                                    (when (writer-present? e) (set hit true)))
                                  hit))
          arm-row (fn [raw a]
                    (cond
                      (nil? raw) (unless (own-writer-present? a) (own-cols a))
                      (dictionary? raw) (get raw :known)
                      true raw))
          l* (parq-cols (get tree :left))
          r* (when (get tree :right) (parq-cols (get tree :right)))
          l (arm-row l* (get tree :left))
          r (when (get tree :right) (arm-row r* (get tree :right)))
          # the TWO-STATE ROW (B-1): membership over the union of the
          # DECIDED arms' rows; nil only when nothing is decided
          undec? (or (dictionary? l*)
                     (and (nil? l*) (not (nil? l)))
                     (and (get tree :right)
                          (or (dictionary? r*)
                              (and (nil? r*) (not (nil? r))))))]
      (when (and l (or (not (get tree :right)) r))
        (if undec?
          {:known (tuple ;(array/concat @[] l (or r @[]))) :kind :row}
          (tuple ;(array/concat @[] l (or r @[]))))))
    (get tree :right)
    (tuple ;(output-columns-raw (get tree :right) catalog memo key-of id-map))
    nil))
# the tree-scoped entry: it builds the key map once and threads it,
# so no caller chooses a catalogue key
(defn/typed output-columns {:args [:any :any] :ret :any} [tree catalog]
  "Best-effort output column names of a tree, given a catalog; nil
when not determinable (catalog absent for its base table)."
  (output-columns-raw tree catalog @{} (source-catalog-key tree)
                      (source-identity-map tree)))
# identity memo per call: a shared subtree's output
# source columns are the catalogue's, read through the shared resolver
# (source-columns), which is why the key map is built from the whole tree:
# it needs each source's keys to answer for any key
# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn output-columns* {:args [:table :any :any :any :any] :ret :any} [key-of tree catalog memo &opt id-map]
  "Best-effort output column names of a tree, given a catalog; nil
when not determinable (catalog absent for its base table)."
  ((fn memoised [t]
     (if (struct? t)
       # a pass-through chain is NOT memoised. Two
       # macro-built chains of the same shape are content-equal structs, so
       # a hash memo hands the second one the first one's answer and the
       # walk below never runs for it. The memo still serves the shared
       # subtrees, which are the ones that made diamonds exponential.
       (let [chain? (not (nil? (index-of (get t :node)
                                         [:query :where :limit :order :distinct])))]
         (if (and (not chain?) (has-key? memo t))
           (get memo t)
           (let [v (output-columns-raw t catalog memo key-of id-map)]
             (unless chain? (put memo t v))
             v)))
       nil))
   tree))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn expand-tree
  [tree &opt catalog]
  "The tree pass: full validation of shape, catalog name checks (when
a catalog is given - without one the engine is the only
validator), and the coverage-manifest attachment. Returns the
expansion record {:tree :node-types :tables :parquet :columns}."
  # freeze FIRST: the value validated below is the value every later
  # reader (renderers included) sees, so a caller-held array alias can
  # no longer change an expanded tree (contract 1 inert data)
  (def tree* (freeze-slots tree))
  (def rec @{:tree tree* :node-types @[] :tables @[] :parquet @[]})
  (defn bad [node why]
    (err :malformed-tree {:node node :why why}))
  # one visit per map-like value: a value reached twice through an alias
  # is validated once (the pre-selection walks already refused cycles). The
  # done-set is keyed by IDENTITY, so a shared subtree costs one visit and
  # a diamond tree stays linear in node count
  (def done @{})
  (defn walk [t]
    (cond
      (not (struct? t)) (bad t :node-not-struct)
      (= :query (get t :node))
      (do (check! (get t :tree) :malformed-tree {:node t :why :query-without-tree})
          # a :query node wraps a tree, it is never an operand (fix 10)
          (when (or (get t :input) (get t :sides) (get t :left) (get t :right))
            (err :malformed-tree {:node t :why :query-not-input}))
          (walk (get t :tree)))
      :else
      (do
        (def n (get t :node))
        # a :query wrapper reached in an operand slot (input, side,
        # left/right) is malformed: wrapping is a top-level act, an
        # operand must be a tree node (fix 10, contract 4 v0.5)
        (each k [:input :left :right]
          (def v (get t k))
          (when (and (dictionary? v) (= :query (get v :node)) (not= :query n))
            (err :malformed-tree {:node v :why :query-not-input})))
        (when (get t :sides)
          (each s (get t :sides)
            (when (and (dictionary? s) (= :query (get s :node)))
              (err :malformed-tree {:node s :why :query-not-input}))))
        (unless (index-of n known-ops) (bad t :unknown-node))
        (unless (or (get t :input) (get t :sides) (get t :left)
                    (index-of n [:from :from-parquet]))
          (bad t :missing-input))
        (case n
          :from
          (do (def src (get t :src))
              (unless (or (keyword? src) (string? src) (struct? src) (table? src))
                (bad t :from-source-type))
              # a handle naming no usable backend: expansion (the public
              # entry, contract 4.3) still refuses the shape. The prepare
              # pipeline selects first, so the SAME tree raises
              # :backend-ambiguous there and this branch never fires.
              (when (and (or (struct? src) (table? src)) (nil? (handle-backend src)))
                (bad t :handle-without-backend))
              (when (or (keyword? src) (string? src))
                (array/push (get rec :tables) (if (keyword? src) src (keyword src))))
              (when (get t :alias)
                (unless (or (keyword? (get t :alias)) (string? (get t :alias)))
                  (bad t :alias-type))))
          :from-parquet
          (do (check! (string? (get t :path)) :malformed-tree
                      {:node t :why :parquet-path-type})
              # a :src handle is provenance for the parquet node exactly as
              # it is for a :from node: a
              # handle naming no usable backend is the same tree-pass class
              (def hsrc (get t :src))
              (when (and (or (struct? hsrc) (table? hsrc))
                         (nil? (handle-backend hsrc)))
                (bad t :handle-without-backend))
              # the path AND the node's alias are catalog source keys
              # (contract 4 v0.5: catalogued under its SOURCE KEY) - the
              # caller's catalog presence decides which one is used
              (array/push (get rec :parquet) (get t :path))
              (when (get t :alias)
                (array/push (get rec :parquet) (get t :alias))))
          :where (valid-expr (get t :pred) :where-pred)
          :join
          (do (each k [(get t :lkeys) (get t :rkeys)]
               (unless (indexed? k) (bad t :join-keys-not-indexed))
               (each kk k
                 (unless (or (keyword? kk) (string? kk))
                   (bad t :join-key-type))))
              (unless (index-of (get t :type)
                                [:inner :left :full :anti :asof :wco])
                (bad t :join-type)))
          :distinct nil
          :group
          (do (unless (indexed? (get t :keys)) (bad t :group-keys-not-indexed))
              (unless (indexed? (get t :aggs)) (bad t :group-aggs-not-indexed))
              (each a (if (indexed? (get t :aggs)) (get t :aggs) [(get t :aggs)])
                (unless (and (struct? a) (= :agg (get a :expr)))
                  (bad t :group-agg-not-aggregate))
                # an aggregate's ARGUMENT is a column REFERENCE. A literal, a string literal and an
                # arbitrary expression are not references; they refuse the
                # malformed class here rather than reaching expr-name's "0"
                # fallback, which used to publish `count_0`. The tag is the
                # one a regression test already asserts for a raw scalar
                # argument, so no verdict class moves
                (def arg (get a :arg))
                (unless (and (struct? arg) (= :get (get arg :expr)))
                  (bad t :group-agg))
                (valid-expr a :group-agg)))
          :select
          (do (unless (indexed? (get t :cols)) (bad t :select-cols-not-indexed))
              (each c (get t :cols)
                (cond (struct? c) (valid-expr c :select-col)
                      (or (keyword? c) (string? c)) nil
                      (bad t :select-col-type))))
          :order
          (each k (get t :keys)
            (unless (and (struct? k) (index-of (get k :dir) [:asc :desc])
                         (or (keyword? (get k :col)) (string? (get k :col))))
              (bad t :order-key)))
          :limit
          (do (unless (number? (get t :n)) (bad t :limit-n-type))
              (unless (index-of (get t :form) [:head :tail])
                (bad t :limit-form)))
          :append
          (do (def sides (get t :sides))
              (unless (indexed? sides) (bad t :append-sides))
              (each s sides (walk s))
              (cond (= 1 (length sides)) (walk (sides 0))
                    (< (length sides) 2) (bad t :append-sides))
              (when catalog
                (def cols
                  (seq [s :in sides] (output-columns s catalog)))
                (when (all identity cols)
                  (def n0 (length (cols 0)))
                  (each c cols
                    (unless (= n0 (length c))
                      (err :malformed-tree {:node t :why :append-column-mismatch}))))))
          :write-parquet
          (check! (string? (get t :path)) :malformed-tree
                  {:node t :why :parquet-path-type})
          :escape
          (do (unless (keyword? (get t :backend)) (bad t :escape-backend-type))
              (unless (string? (get t :text)) (bad t :escape-text-type)))
          :window nil
          :pivot nil
          nil)
        # a child reached through two slots is walked once, never twice
        # (a value reached twice through an alias is expanded once; the
        #  pre-selection walks already refused real cycles)
        (each k [:left :right :input]
          (def v (get t k))
          (def id (ident-key v))
          (when (and v (not (get done id)))
            (put done id true)
            (walk v)))
        (when (get t :sides)
          (each s (get t :sides)
            (def id (ident-key s))
            (unless (get done id) (put done id true) (walk s)))))))
  (walk tree*)
  # the source key map is built ONCE for the whole pass and read by every
  # lane below; building it here rather than at the first
  # consumer lets the name-check lane ask "does the catalogue name this
  # arm?" through the resolver instead of a single-key lookup
  (def key-of (source-catalog-key tree*))
  # the RECORD identity of every binding spelling, built once beside
  # the key map and handed to the lanes that must tell one source from
  # another. It never replaces `key-of`: the
  # spelling->canon map stays the answer wherever a path is wanted.
  (def id-map (source-identity-map tree*))
  # the filter above IS the arm's name check: a parquet key enters pq-keys only
  # when the record-based resolver names it, so there is nothing left for this
  # lane to re-adjudicate. Only from-table names are checked here, literally.
  (each tab (get rec :tables)
    (when catalog
      (unless (catalog-entry-at catalog tab)
        (err :unknown-table {:name tab}))))
  (when catalog
    # per-SOURCE scoping: a reference is
    # checked against the catalog entry of the source it binds to, never
    # against the union of every source's columns - a sibling's column must
    # not validate a reference on this source, and a source the catalog does
    # not name (an unnamed parquet side) defers to the engine instead
    # of being refused
    (defn source-known-cols [src path]
      # G1: the source's columns by BOTH of its keys, through the
      # shared resolver - never by whichever key the caller chose. The key
      # map is required to exist before this lane (it is defined below).
      #
      # (measured): this is the ONE resolution site that must keep the
      # (src, path) form. Handing it a rebuilt record made the path-gated
      # shared-block guard run for a from source, which turned a GENUINE
      # shared block into a serve (D3 genuine-block cell, smoke m2r-4). A
      # row's source is a key, not a record, and its own entry must still be
      # reachable by its path.
      (source-columns catalog key-of src path id-map))
    # rows are grouped by catalog key: a reference is checked against the
    # entry of the source it binds to. An UNQUALIFIED reference is recorded
    # once per source it could bind to, so it is checked only when EVERY
    # such source is catalogued - otherwise the column may belong to the
    # unnamed source and the engine keeps it (an unnamed source is unnamed, not unknown)
    (var rows (tree-columns tree*))
    (def src-cols @{})
    (defn src-known [k]
      # the row's own source columns, by every key that source answers to
      #: cached per source key
      (if (has-key? src-cols k) (get src-cols k)
        (do (def v (source-known-cols k nil))
            (put src-cols k v)
            v)))
    # computed columns
    # a node's input decides its own computed names (ruling 1A: "beneath the
    # reference" is the reference's data path, never the whole tree). The
    # nearest operator's committed output is the boundary; the pass-through
    # operators (row unchanged) forward their input's names.
    (def local-memo @{})
    (defn local-outputs [t]
      (def id (ident-key t))
      (if-let [v (get local-memo id)]
        v
        (let [v* (output-columns* key-of t catalog @{} id-map)]
          (put local-memo id v*)
          v*)))
    # a join's row is the union of its ARMS' OWN
    # rows, and a source arm answers with the entry it owns (source-columns
    # under the identity map) - never with the union above it, which would
    # let a text two sources share testify for either one. An arm nobody
    # describes leaves the union undeterminable, so the reference defers
    # exactly as it did for an uncatalogued arm.
    (def join-row-memo @{})
    # An arm RESOLVES three ways, and the
    # middle one is the whole point. `known` serves; `unknown` defers - the
    # conservative read, unchanged; `foreign` REFUSES. Folding foreign
    # into unknown made a key proven to name a sibling defer the arm into
    # serving that sibling's description, which the identity rule forbids.
    (def arm-verdict-memo @{})
    (defn parquet-arm-verdict
      [a]
      # :known -> {:cols [...]}, :foreign -> :foreign, :unknown -> :unknown.
      # Foreign is decided by the ARM's own keys resolving to a different
      # source record: only an arm whose own spellings name another record
      # can be refuted; an arm nothing resolves stays simply unknown.
      (def id (ident-key a))
      (if-let [v (get arm-verdict-memo id)]
        v
        (let [p (get a :path)
              sc (source-columns catalog key-of p p id-map)
              # spellings the arm itself answers to, per the ARM RECORD: a
              # table keyed binding -> canon, so its KEYS are the spellings
              own (keys (arm-keys a))
              # R7: foreign means the arm's own spellings DO resolve, and the
              # resolution is a different record. An arm whose spellings bind
              # to nothing is unknown, not foreign - absence is not a claim.
              bound (filter (fn [kk] (not (nil? (binding-source id-map kk)))) own)
              foreign? (and (dictionary? id-map)
                            (not (nil? p))
                            (> (length bound) 0)
                            (not (find (fn [kk] (same-source? id-map p kk)) bound)))
              v* (cond foreign? :foreign
                       (nil? sc) :unknown
                       true {:cols sc})]
          (put arm-verdict-memo id v*)
          v*)))
     (defn local-join-row [t]
      (def id (ident-key t))
      (if-let [v (get join-row-memo id)]
        v
        (let [arms (filter |(and (struct? $) (or (get $ :path) (get $ :src)))
                           [(when (struct? t) (get t :left))
                            (when (struct? t) (get t :right))])
              arm-verdict (fn [a]
                            (case (get a :node)
                              # a from arm is addressed by its SOURCE,
                              # a parquet arm by its record
                              :from (let [o (local-outputs a)] (if o {:cols o} :unknown))
                              # the arm's own reference, never `arm-binding-key`
                              # - an arm addressed by an alias a sibling also
                              # uses as its PATH resolves to the sibling's
                              # record, which is the leak itself
                              :from-parquet (parquet-arm-verdict a)
                              (let [o (local-outputs a)] (if o {:cols o} :unknown))))
              vs (map arm-verdict arms)
              v* (cond
                   # A foreign arm refuses the join's row. Refusal
                   # is carried as the :foreign marker so the key lane above
                   # can name the column; it is never read as a row.
                   (find |(= :foreign $) vs) :foreign
                   (or (= 0 (length vs))
                       (find |(= :unknown $) vs)) nil
                   true (tuple ;(mapcat |(get $ :cols) vs)))]
          (put join-row-memo id v*)
          v*)))
    # the COMPUTED names a node's data path publishes: a group's aggregate
    # outputs, plus whatever a pass-through operator forwards from its
    # input. Stored source columns are never computed names.
    (def comp-memo @{})
    (defn computed-outputs [x]
      (if (not (struct? x))
        @{}
        (or (get comp-memo (ident-key x))
            (let [v (case (get x :node)
                      # a group COMPUTES its aggregates (and vars); the key
                      # entries merely re-expose input columns and are not
                      # computed names (counting the keys let a name the input never supplies exempt itself)
                      :group (table ;(mapcat (fn [a]
                                               [(string (keyword (expr-name a))) true])
                                             (or (get x :aggs) @[])))
                      # a select computes only its :as/:alias names; a bare
                      # entry re-exposes a stored column and names nothing
                      :select (table ;(mapcat (fn [c]
                                                (def nm (and (struct? c)
                                                             (or (get c :as) (get c :alias))))
                                                (if nm [(string (keyword nm)) true] []))
                                             (or (get x :cols) @[])))
                      # a pass-through forwards its input's computed names;
                      # an append is POSITION-ALIGNED, so a side's names count
                      # only where the appending row actually carries them
                      # (the side union published a name the appending result does not have)
                      (do
                       (var v (merge @{} (or (computed-outputs (get x :input)) @{})
                                     (or (computed-outputs (get x :left)) @{})
                                     (or (computed-outputs (get x :right)) @{})))
                       (def app? (= :append (get x :node)))
                       (when (get x :sides)
                         (each s (get x :sides)
                           (set v (merge v (or (computed-outputs s) @{})))))
                       # POSITION-ALIGNED: the appending row takes
                       # its shape from the FIRST side, so only a name that
                       # side's own output carries can be a column of the
                       # result; a later side's name is not (an unaligned
                       # union published it and exempted a foreign column)
                       (when app?
                         (def sides (or (get x :sides) @[]))
                         (def base (when (> (length sides) 0)
                                     (def o (output-columns (sides 0) catalog))
                                     (when o
                                       (table ;(mapcat |[(string (keyword $)) true] o)))))
                         (set v (table ;(mapcat (fn [[k _]]
                                                  (if (and base (get base k)) [k true] []))
                                                (pairs v)))))
                       v))]
              (put comp-memo (ident-key x) v)
              v))))
    (defn contains-computed? [x c]
      # Does x's OUTPUT publish c as a COMPUTED name? Distinct from
      # known-computed?: that asks what the nearest ARM computes, this asks
      # what x itself publishes, which is the supplier question proven?
      # answers for the boundary lane.
      (not (nil? (get (computed-outputs x) (string (keyword c))))))
     # The PASS-THROUGH union - every name a pass-through
    # node's input PUBLISHES (a where/order/limit/distinct/query forwards its
    # input's row whole). The own-path readers (`known-computed?`,
    # `contains-computed?`) answer only for a node whose row is its own
    # output, which is why a bare pass-through could not see a computed
    # name one node below.
    (defn- pass-through? [x]
      (and (struct? x)
           (or (index-of (get x :node) [:where :limit :order :distinct :query])
               (and (= :select (get x :node)) (nil? (get x :cols))))))
    (defn forwarded-outputs [x]
      (merge @{}
             (or (computed-outputs x) @{})
             (or (when (pass-through? x)
                   (forwarded-outputs (or (get x :input) (get x :tree))))
                 @{})))
    # The exemption vouches for a name the input PUBLISHES as
    # a declaration too, not only one it computes. A declared row WRITES its
    # entries; the entry's source column is proof-checked at the node that
    # declares (the rename launder).
    (defn declared-writes? [x c]
      (def want (string (keyword c)))
      (and (struct? x)
           (not (nil? (get (forwarded-outputs x) want)))))

    # the cited node's own input names one column: this is the ONLY
    # writer of the computed exemption, so a name computed elsewhere in the
    # tree never exempts a reference here (a replaced subtree, the far arm
    # of a join)
    (defn known-computed? [t ck]
      "Does the referencing node's own data path produce this name? The
node's input decides; a join/append REPOSITIONS its arms, so a name an
arm exposes is visible at the join too (the legitimate computing-arm
refs). A replaced subtree is not an arm and never qualifies."
      (var want (string (keyword ck)))
      (when (declared-writes? (get t :input) ck) (set want (string (keyword ck))))
      (defn out? [outs]
        (and outs
             (not (nil? (find |(= want (string (if (keyword? $) (keyword $) (string $))))
                              outs)))))
      # nodes that COMPUTE outputs are the only ones whose output columns a
      # computed name can come from: a group's aggregate alias, a select's
      # :as/:alias. A join or append merely UNIONS its arms' STORED columns,
      # which are not computed names and must not be exempted (the arm union is a source surface, not a computation).
      (defn names? [x]
        (if (and (struct? x) (= :select (get x :node)))
          # a select names only the entries it COMPUTES (:as/:alias); a bare
          # stored reference re-exposes a source column, which stays a stored
          # reference above it
          (some (fn [c]
                  (and (struct? c)
                       (or (get c :as) (get c :alias))
                       (= want (string (keyword (or (get c :as) (get c :alias)))))))
                (or (get x :cols) @[]))
          (not (nil? (get (computed-outputs x) want)))))
      # an append is POSITION-ALIGNED, so a side's
      # computed name reaches the appending row only where the side's output
      # carries it; a join REPOSITIONS its arms, so an arm's name is visible at
      # the join. Either way the name must be a COLUMN of the
      # operator result, never a name merged in from a side that dropped it.
      (defn arm-produced? [sd]
        (and (struct? sd)
             (not (index-of (get sd :node) [:from :from-parquet]))
             (names? sd)
             (out? (local-outputs sd))))
      (or (names? (get t :input))
          (some arm-produced? (or (get (get t :input) :sides) @[]))
          (arm-produced? (get (get t :input) :left))
          (arm-produced? (get (get t :input) :right))
          (declared-writes? (get t :input) ck)))
    # knows which OUTPUTS sit beneath (computed columns).
    (defn operator-refs [t]
      (def out @[])
      (def tab-alias @{})
      (def tab-cat @{})
      # a shared subtree is described once per identity (the descender has no memo, so a diamond costs 2^depth)
      (def wseen @{})
      (defn walk-src [s]
        (when (struct? s)
          (def id (ident-key s))
          (unless (get wseen id)
            (put wseen id true)
            (case (get s :node)
              :from (do (put tab-alias (get s :src) (or (get s :alias) false))
                        (put tab-cat (get s :src) (get s :src)))
              :from-parquet (do (def pk (or (get s :alias) (get s :path)))
                                (put tab-alias pk (or (get s :alias) false))
                                (put tab-cat pk (get s :path)))
              :query (walk-src (get s :tree))
              nil)
            (walk-src (get s :input))
            (when (get s :sides) (each x (get s :sides) (walk-src x)))
            (when (get s :left) (walk-src (get s :left)))
            (when (get s :right) (walk-src (get s :right))))))
      # SELF first: a node's own storage shape (:from/:from-parquet) is how an
      # unqualified reference binding to the node ITSELF is resolved
      (walk-src t)
      # then its data path: an unqualified reference emitted by this node is
      # resolved against the sources BENEATH it. For a join/asof that is the
      # arms (a key and an arm-union reference may name a column of either).
      # For a selector the path is :input ALONE: an arm that happens to sit
      # in the same join is a SIBLING source, and binding to it made a
      # reference valid on a source its own subtree never reads (the sibling row was then refused as an unknown column).
      (defn walk-path [s]
        (when (struct? s)
          (def id (ident-key s))
          (unless (get wseen id)
            (put wseen id true)
            (case (get s :node)
              :from (do (put tab-alias (get s :src) (or (get s :alias) false))
                        (put tab-cat (get s :src) (get s :src)))
              :from-parquet (do (def pk (or (get s :alias) (get s :path)))
                                (put tab-alias pk (or (get s :alias) false))
                                (put tab-cat pk (get s :path)))
              :query (walk-path (get s :tree))
              nil)
            (walk-path (get s :input))
            (when (get s :sides) (each x (get s :sides) (walk-path x)))
            (when (get s :left) (walk-path (get s :left)))
            (when (get s :right) (walk-path (get s :right))))))
      (def arms? (or (= :join (get t :node)) (= :asof (get t :node))))
      (when arms?
        (when (get t :sides) (each x (get t :sides) (walk-path x)))
        (when (get t :left) (walk-path (get t :left)))
        (when (get t :right) (walk-path (get t :right))))
      (when (get t :input) (walk-path (get t :input)))
      (defn emit [a c]
        (def ck (keyword c))        (when (known-computed? t ck) (array/push out ck))
        (def hits (seq [tab :in (sort (keys tab-alias))
                        :when (alias-match tab-alias tab a)] tab))
        # an unqualified reference is checked ONCE, against the union row
        # emitted below: a per-source row here would refuse it on a single
        # source before the union rule (any-source) is consulted
        (if (empty? hits)
          (do
            (when a (array/push out [nil a c nil]))
            # an UNQUALIFIED reference whose data path
            # records no source leaves nothing in the lane, and an empty lane
            # is indistinguishable from a bound one - the per-source
            # conjunction then reads "all catalogued" and the name vanishes.
            # Record the reference boundary explicitly.
            (when (nil? a) (array/push out [nil nil c nil nil])))
          (each tab hits (array/push out [tab a c (get tab-cat tab)])))
        (when (nil? a)
          (def urow (array/new 5))
          (array/push urow :u) (array/push urow nil) (array/push urow c)
          (array/push urow nil) (array/push urow nil)
          (array/push out urow)))
      (defn emit-expr [e] (each [a c] (expr-columns e) (emit a c)))
      (when (get t :expr) (emit-expr (get t :expr)))
      (when (struct? (get t :pred)) (emit-expr (get t :pred)))
      (when (get t :keys)
        (each k (get t :keys) (if (struct? k) (emit-expr k) (emit nil k))))
      (when (get t :cols)
        (each c (get t :cols) (if (struct? c) (emit-expr c) (emit nil c))))
      (when (get t :aggs)
        (each a (if (indexed? (get t :aggs)) (get t :aggs) []) (when (struct? a) (emit-expr a))))
      (when (get t :lkeys)
        (each lk (get t :lkeys) (array/push out [nil "__lkey" lk])))
      (when (get t :rkeys)
        (each rk (get t :rkeys) (array/push out [nil "__rkey" rk])))
      out)
    # computed-name exemption, SUBTREE-scoped (ruling 1A). A reference is
    # exempt when the node that makes it produces the name from its OWN
    # input. The removed flat tree-wide set let a name computed by a
    # replaced subtree or the far arm of a join exempt anything; here the
    # test runs per referencer and the matching row is DROPPED from the
    # stored lane, so every surviving row is a real source reference
    # (every-candidate or named-source decides those).
    (defn drop-refs! [t c]
      "Drop the STORED rows an exempt name refers to: unqualified rows only.
An alias-qualified row names a source the alias resolution must still
validate (an unknown alias stays a raise)."
      (def nm (string (keyword c)))
      (var i (dec (length rows)))
      (while (>= i 0)
        (def row (get rows i))
        # a 5-slot tuple reads index 0 as a METHOD CALL in janet, so the row
        # is read through its call slots (a 3-slot tuple is unaffected)
        (when (and (indexed? row)
                   (nil? (row 1))
                   (= nm (string (keyword (row 2)))))
          (array/remove rows i))
        (-- i)))
    (defn group-arg-col? [t c]
      "Is this column an aggregate ARGUMENT of the group node? A group's
aggregate argument is judged inside the group's own scope, so it must
not survive into an ancestor's row check. A key
is not an argument: it re-exposes an input column and stays a
reference the row check judges."
      (def nm (string (keyword c)))
      (var hit false)
      (each a (or (get t :aggs) @[])
        (def arg (get a :arg))
        (when (and (struct? arg) (= :get (get arg :expr)))
          (when (= nm (string (keyword (get arg :col)))) (set hit true))))
      hit)
    (def wrefs-seen @{})
    (defn drop-refs!* [t c]
      "Drop every stored row naming this column, qualified or not. A group's aggregate argument is judged inside the
group's own scope: its row must not survive into an ancestor's
judgement, where the group's published row (keys + computed names)
legitimately lacks it. Wider than drop-refs!, which keeps alias rows
for the alias-resolution lane."
      (def nm (string (keyword c)))
      (var i (dec (length rows)))
      (while (>= i 0)
        (def row (get rows i))
        (when (and (indexed? row)
                   (= nm (string (keyword (row 2)))))
          (array/remove rows i))
        (-- i)))
    # the PUBLISHED ROW. A reference is judged against
    # the row its immediate input publishes, not against a lane label on
    # some node below it. Three rules, one row: a pass-through hands on
    # the row beneath it; a select that declares a projection publishes
    # exactly it (bare, get and string entry forms alike); a join
    # publishes the union of its arms, unknown where any arm is
    # unresolvable. Returns {:cols <tuple or nil> :open? <boolean>};
    # :open? means "no published contract - the engine decides".
    # nil means "no answer - keep the pre-existing per-source lanes".
    (defn declared-projection [s]
      # an ABSENT list is an absent declaration: a select that declares
      # nothing is a pass-through, never a declared-empty projection
      #
      (when (and (struct? s) (= :select (get s :node)))
        (when-let [cs (get s :cols)] (when (> (length cs) 0) cs))))
    (defn unnamed-beneath? [a]
      "Is a verdict undeterminable because this subtree holds an arm the
CATALOGUE cannot speak for? VERDICT-DETERMINATION is catalogue-BLIND: a from-parquet arm is
unnamed by construction, so cataloguing its alias never flips a
deferral into a refusal. Union membership is the OTHER predicate
(arm-resolvable?) and only decides which columns enter the known
union."
      (and (dictionary? a)
           (or (unnamed-arm? a)
               (and (or (= :join (get a :node)) (= :asof (get a :node)))
                    (or (unnamed-beneath? (get a :left))
                        (unnamed-beneath? (get a :right))))
               (and (or (= :where (get a :node)) (= :limit (get a :node))
                        (= :order (get a :node)) (= :distinct (get a :node))
                        (= :query (get a :node)))
                    (or (unnamed-beneath? (get a :input))
                        (unnamed-beneath? (get a :tree))))
               (and (= :select (get a :node))
                    (unnamed-beneath? (get a :input))))))
    # the published row is asked once per node identity: without the memo a
    # diamond tree costs 2^depth inside expand-tree, which the walk budget
    # cell (r3R-fix3) pins for depth 14
    (def pub-memo @{})
    (var- published-row nil)
    (defn published-row-raw [x]
      (when (struct? x)
        (let [nd (get x :node)]
          (cond
            (or (= :where nd) (= :limit nd) (= :order nd)
                (= :distinct nd) (= :query nd))
            (published-row (or (get x :input) (get x :tree)))
            (= :select nd)
            (if-let [cs (declared-projection x)]
              {:cols (tuple ;(map (fn [k] (if (struct? k)
                                            (or (get k :as) (get k :alias)
                                                (get k :col))
                                            k))
                                  cs))
               :open? false}
              (published-row (get x :input)))
            (or (= :join nd) (= :asof nd))
            (let [lo (local-outputs x)]
              (cond
                # The two-state row is a ROW, never an
                # open deferral - the undecidable-identity join decides by
                # membership over its decided union
                (and lo (has-key? lo :kind))
                {:cols (get lo :known) :open? false :undecidable? true}
                (or (unnamed-beneath? (get x :left))
                    (unnamed-beneath? (get x :right)))
                {:cols nil :open? true}
                true (if lo {:cols lo :open? false} nil)))
            (get x :sides)
            (if (some unnamed-beneath? (get x :sides))
              {:cols nil :open? true}
              (do (def lo (local-outputs x))
                  (if lo {:cols lo :open? false} nil)))
            (= :group nd)
            (if (unnamed-beneath? x)
              {:cols nil :open? true}
              (do (def lo (local-outputs x))
                  (if lo {:cols lo :open? false} nil)))
            true nil))))
    (set published-row
         (fn [x]
           (if (not (struct? x))
             nil
             (let [id (ident-key x)]
               (if (has-key? pub-memo id)
                 (get pub-memo id)
                 (let [v (published-row-raw x)]
                   (put pub-memo id v)
                   v))))))
    (defn in-row? [r c]
      (let [cs (when r (get r :cols))]
        (and cs (not (nil? (find |(= (string (keyword $)) (string (keyword c))) cs))))))
    (def lane-memo @{})
    (def sup-memo @{})
    (var- supplied? nil)
    (defn supplied-raw [x c]
      # THE BOUNDARY RULE: a published
      # projection is a REFUSAL BOUNDARY, never an existence proof. The
      # row says what a node HANDS ON, never what its input can produce,
      # so a name the row carries still needs a PROVEN SUPPLIER: a
      # catalogued source's own column list, a JOIN arm's row (both arms
      # resolvable), or a name the node itself computes. A SELECT is
      # never its own supplier - its declaration IS the thing under test,
      # so the proof passes THROUGH it to the input (the circularity the
      # S1 cell pins). No proof, no serve.
      (if (not (struct? x))
        false
        (let [nm (fn [k] (string (keyword k)))
              has? (fn [cols k]
                     (and cols (not (nil? (find |(= (nm $) (nm k)) cols)))))]
          (cond
            (known-computed? x c) true
            (= :select (get x :node)) (supplied? (get x :input) c)
            # a pass-through hands its input's row on: the proof is below
            (index-of (get x :node) [:where :limit :order :distinct :query])
            (supplied? (or (get x :input) (get x :tree)) c)
            (or (= :join (get x :node)) (= :asof (get x :node)))
            (or (has? (local-outputs (get x :left)) c)
                (has? (local-outputs (get x :right)) c))
            (get x :sides) (some |(has? (local-outputs $) c) (get x :sides))
            :else (has? (local-outputs x) c)))))
    (set supplied?
         (fn [x c]
           (if (not (struct? x))
             (supplied-raw x c)
             (let [k (tuple (ident-key x) (string (keyword c)))]
               (if (has-key? sup-memo k)
                 (get sup-memo k)
                 (let [v (supplied-raw x c)]
                   (put sup-memo k v)
                   v))))))
    # WHICH recorded source proves a
    # name. `supplied?` is EXISTENCE - any catalogued source's columns plus
    # the operator's own output - so it let a SIBLING's entry serve: a
    # parquet arm whose own entry does not carry the name was credited
    # because a record sharing its text had one that did. A recorded source
    # proves only by an entry it is the OWNER of (`source-columns` under
    # the identity map), and a column list reached only through a shared
    # metadata block proves nothing. A computation and an
    # operator's own output still prove; only the source case narrows.
    (var- proven? nil)
    (defn proven-raw [x c]
      (if (not (struct? x))
        false
        (let [nm (fn [k] (string (keyword k)))
              has? (fn [cols k]
                    (and cols (not (nil? (find |(= (nm $) (nm k)) cols)))))]
          (cond
            (known-computed? x c) true
            (index-of (get x :node) [:from :from-parquet])
            (has? (source-columns catalog key-of (arm-binding-key x)
                                 (get x :path) id-map) c)
            (= :select (get x :node)) (proven? (get x :input) c)
            (index-of (get x :node) [:where :limit :order :distinct :query])
            (proven? (or (get x :input) (get x :tree)) c)
            (or (= :join (get x :node)) (= :asof (get x :node)))
            (or (proven? (get x :left) c) (proven? (get x :right) c))
            (get x :sides) (some |(proven? $ c) (get x :sides))
            # a computing NODE supplies the names it publishes: a group's
            # aggregate alias or a select's rename. Without this arm the proof
            # the target clause accepts as `:in` never reaches a node whose row
            # is its own output.
            (contains-computed? x c) true
            :else (has? (local-outputs x) c)))))
    (set proven?
         (fn [x c]
           (if (not (struct? x))
             (proven-raw x c)
             (let [k (tuple (ident-key x) (string (keyword c)))]
               (if (has-key? sup-memo k)
                 (get sup-memo k)
                 (let [v (proven-raw x c)]
                   (put sup-memo k v)
                   v))))))
    (defn published-lane* [x c]
      # the THREE-STATE BOUNDARY,
      # with the boundary rule applied inside PUBLISHED. PUBLISHED: the
      # nearest enclosing projection is a CEILING - a name inside it is
      # JUDGED, serving only where a proven supplier backs it (:in) and
      # refusing otherwise (:out for a name the row lacks, :noproof for
      # one it carries without proof; both refuse). No arm, key or inner
      # publish rescues a name the ceiling refuses (the chain launder).
      # EMPTY/ABSENT: published-row returns nil for a cols-less select,
      # so this lane declines and the input's row passes through.
      # UNDETERMINABLE: an OPEN row defers.
      (let [r (published-row x)]
        (cond
          (nil? r) nil
          (get r :open?) :open
          # Membership over the decided union - a
          # carried name serves, an unknown one refuses; attribution is
          # not asked of the undecidable-identity row
          (get r :undecidable?) (if (in-row? r c) :in :out)
          # CR13 R2c: the ROW is the boundary first. A
          # name the published row LACKS is :out even where a supplier proof
          # would pass (a join arm, a computed name): the row is the ceiling
          # and membership decides it. A name the row CARRIES still needs its
          # proof (:in serves, :noproof refuses).
          (not (in-row? r c)) :out
          (proven? x c) :in
          :else :noproof)))
    (defn published-lane [x c]
      # asked once per (node identity, column): the walk consults the lane
      # for every stored reference, and an unmemoised descent here costs a
      # power of the tree on a diamond (r3R-fix3 pins the budget)
      (if (not (struct? x))
        (published-lane* x c)
        (let [k (tuple (ident-key x) (string (keyword c)))]
          (if (has-key? lane-memo k)
           (get lane-memo k)
           (let [v (published-lane* x c)]
             (put lane-memo k v)
             v)))))
    (def pub?-memo @{})
    (var- publishes? nil)
    (defn publishes?-raw [x]
      # does any node from x downward declare a projection? The ceiling
      # outranks the lanes that would otherwise decide, so they must know
      (and (struct? x)
           (or (not (nil? (declared-projection x)))
               (publishes? (get x :input))
               (publishes? (get x :tree)))))
    (set publishes?
         (fn [x]
           (if (not (struct? x))
             false
             (let [id (ident-key x)]
               (if (has-key? pub?-memo id)
                 (get pub?-memo id)
                 (let [v (publishes?-raw x)]
                   (put pub?-memo id v)
                   v))))))
    (def src-cat-memo @{})
    (var- all-sources-catalogued? nil)
    (defn all-sources-catalogued?* [x]
      (if (not (struct? x))
        true
        (and (case (get x :node)
               # R2: the question is DESCRIPTION, never catalogue presence
               # - an entry that describes nothing leaves the
               # arm undescribed, exactly as no entry at all does
               :from (not (nil? (source-catalogued? catalog key-of
                                                     (get x :src) nil id-map)))
               # G1: every key the arm answers to, one resolver
               # R2d: `id-map` belongs in this patch as it does in `:from`'s
               # above. The lane the 4-arg call dropped is the WRITER-IDENTITY
               # admission in source-columns, not alias resolution: a parquet
               # arm whose entries carry a :writer is admitted only when the
               # map resolves both the arm and the writer, so without it the
               # entry contributes nothing, the arm reads undescribed, the
               # row is undeterminable, and the without-projection deferral
               # serves the target (measured: alias+path with writers served on 4-arg, refused on 5-arg,
               # alias-only fieldless refused either way).
               :from-parquet (not (nil? (source-catalogued? catalog key-of
                                                              (or (get x :alias) (get x :path))
                                                              (get x :path) id-map)))
               true)
             (all-sources-catalogued? (get x :input))
             (all-sources-catalogued? (get x :tree))
             (all true? (map all-sources-catalogued? (or (get x :sides) @[])))
             (all-sources-catalogued? (get x :left))
             (all-sources-catalogued? (get x :right)))))
    (set all-sources-catalogued?
         (fn [x]
           # the memo is keyed by IDENTITY: a value key is structural and
           # answers nothing for a rebuilt equal subtree (the diamond walk budget stays closed)
           (if (not (struct? x))
             true
             (let [id (ident-key x)]
               (if (has-key? src-cat-memo id)
                 (get src-cat-memo id)
                 (let [v (all-sources-catalogued?* x)]
                   (put src-cat-memo id v)
                   v))))))
    # the QUALIFIER is the witness. Computed once per
    # expand-tree (never per node - shared subtrees are walked once), it
    # maps every source's alias/key to the catalog key it resolves to.
    (def tab-cat-local @{})
    # two sources naming the same alias make every qualified
    # reference ambiguous, and the alias map is first-wins, so the second
    # source would silently never be reachable. Refused at expansion.
    (def aliased @{})
    (defn note-src [s]
      (when (struct? s)
        (case (get s :node)
          :from (do (def a (get s :alias))
                    (when a
                      (when (get aliased a)
                        (err :malformed-tree {:node s :why :duplicate-alias :alias a}))
                      (put aliased a true))
                    (put tab-cat-local (get s :src) (get s :src))
                    (put tab-cat-local (or a false) (get s :src)))
          :from-parquet (do (def pk (or (get s :alias) (get s :path)))
                            (when (get s :alias)
                              (when (get aliased (get s :alias))
                                (err :malformed-tree {:node s :why :duplicate-alias
                                                      :alias (get s :alias)}))
                              (put aliased (get s :alias) true))
                            (put tab-cat-local pk (get s :path)))
          nil)))
    (def scan-seen @{})
    (defn scan-src [s]
      (when (struct? s)
        (def id (ident-key s))
        (unless (get scan-seen id)
          (put scan-seen id true)
          (note-src s)
          (scan-src (get s :input))
          (when (get s :sides) (each x (get s :sides) (scan-src x)))
          (scan-src (get s :left))
          (scan-src (get s :right))
          (scan-src (get s :tree)))))
    (scan-src tree*)
    (defn walk-refs [t]
      (when (struct? t)
       (def id (ident-key t))
       (unless (get wrefs-seen id)
        (put wrefs-seen id true)
        (if (= :query (get t :node))
          (walk-refs (get t :tree))
          (do
            (def n (get t :node))
            # a select's own column names are its TARGETS, not references:
            # an unqualified one may name a computed column beneath it
            (def own-projection (= :select n))
            # a join key names a column of BOTH arms: it already reached the
            # check through tree-columns (lane-local sentinel rows)
            (def key-lane (or (= :join n) (= :asof n)))
            # INPUT SCOPE: a STORED reference must
            # appear in the referencing node's OWN INPUT outputs. This
            # REPLACES the every-candidate-or-named-source resolution only
            # where that scope is determinable; an undeterminable scope
            # (output-columns nil: uncatalogued base, undecidable shape)
            # defers to the existing per-source rules, never a false
            # refusal.
            # A join has no :input: its operands are :left/:right, and a key
            # names a column of BOTH arms, so the scope of a join's own refs
            # is the UNION of its arm outputs. Judging an arm's refs against
            # the join's key list would refuse the right arm's key column.
            # the selector ABOVE a join is judged on the
            # same union - the merged row carries both arms.
            (defn sides? [x] (and (struct? x) (get x :sides)))
            (defn arms? [x] (and (struct? x) (or (get x :left) (get x :right))))
            # a nil side POISONS the union. An append is
            # position-aligned and every legitimate arm output is known, so a
            # side whose columns are not computable means the appending row is
            # not computable either; coercing it to () was a false refusal.
            (defn near []
              (if (or (= :join n) (= :asof n))
                # A two-state join row reads :known -
                # membership over the decided union decides
                (let [o (local-outputs t)]
                  (if (and (dictionary? o) (has-key? o :kind))
                    (get o :known)
                    (local-join-row t)))
                (if (sides? (get t :input))
                  # the append's row is its sides' alignment; the union is the
                  # best-effort shape (the input's outputs)
                  (let [ss (get (get t :input) :sides)
                        cs (map local-outputs ss)]
                    (var known true)
                    (each c cs (when (nil? c) (set known false)))
                    (when (and known (> (length cs) 0))
                      (tuple ;(mapcat identity cs))))
                  (if (arms? (get t :input))
                    (let [l (local-outputs (get (get t :input) :left))
                          r (local-outputs (get (get t :input) :right))]
                      (when (and l r) (tuple ;(array/concat @[] l r))))
                    (if (and (struct? (get t :input)) (= :group (get (get t :input) :node)))
                      # a group RE-SHAPES its row: its scope is the keys it
                      # projects plus the entries it computes. Its input's
                      # non-key columns are dropped by the group and must not
                      # be in scope above it
                      (let [grp (get t :input)
                            ks (map (fn [k] (if (struct? k) (get k :col) k))
                                    (or (get grp :keys) @[]))
                            comp (computed-outputs grp)]
                        (tuple ;(array/concat @[] ks
                                              (map |(symbol (string $)) (keys comp)))))
                      (local-outputs (get t :input)))))))
            # catalogued arms, but the uncatalogued source may own the
            # column and only the engine can say
            (defn cats? [x]
              (and (all-sources-catalogued? x)
                   (all true? (map all-sources-catalogued?
                                   (or (get x :sides) @[])))))
            (defn determinable []
              (and (not (nil? (near)))
                   (cats? (get t :input))
                   (cats? (get t :left))
                   (cats? (get t :right))))
            # A SELECT over an UNNAMED join publishes its
            # projection. The projection is the select's output contract, so a
            # reference the select carries is judged against exactly that row -
            # a name the projection does not surface is refused instead of
            # deferred. `near` cannot answer there (the join is undeterminable
            # only because an arm is unnamed, which is the case the widening
            # exists for). The junction probes the nearest select's :input:
            # walk-refs is visiting that select. A bare unnamed join keeps its
            # residual deferral (no select above it) and the select echo
            # exemption is untouched (a target inside the projection passes).
            (defn unnamed-join-arm? [a]
              (and (dictionary? a)
                   (or (= :from-parquet (get a :node))
                       (and (or (= :join (get a :node)) (= :asof (get a :node)))
                            (some unnamed-join-arm?
                                  [(get a :left) (get a :right)])))))
            (defn unnamed-join? [a]
              (and (struct? a)
                   (= :join (get a :node))
                   (or (some |(and (dictionary? $)
                                   (= :from-parquet (get $ :node))
                                   # G1: "unnamed" is the shared
                                   # resolver's answer for EVERY key the arm
                                   # answers to, never one key's
                                   (nil? (source-columns catalog key-of
                                                         (arm-binding-key $)
                                                         (get $ :path))))
                             [(get a :left) (get a :right)])
                       (some |(and (unnamed-join-arm? $)
                                   (not (unnamed-join? $)))
                             (or (get a :sides) @[])))))
            (defn unnamed-join-at? [a]
              # the junction predicate: an unnamed JOIN, or an append one of
              # whose sides is a select over one
              (or (unnamed-join? a)
                  (some |(and (struct? $)
                              (= :select (get $ :node))
                              (unnamed-join? (get $ :input)))
                        (when (struct? a) (or (get a :sides) @[])))))
            (defn unnamed-join-key? [j c]
              # is c one of the join's own key slots? The key lane is NOT the
              # projection lane: a key names a column of an ARM to pair rows on,
              # and the widening judges only what a select PUBLISHES. Refusing
              # a key the projection omits would close the documented key-lane
              # gap by accident, so the regression cell - the
              # unnamed arm's key above a select over it - must still defer.
              (and (struct? j)
                   (let [s (string (keyword c))]
                     (or (some |(= s (string (keyword $))) (or (get j :lkeys) @[]))
                         (some |(= s (string (keyword $))) (or (get j :rkeys) @[]))))))
            (defn projection-shows? [s c]
              # does this select's own projection surface the name? A bare
              # entry shows itself; an expression shows its :as/:alias.
              (some (fn [k]
                      (= (string (keyword c))
                         (string (keyword (if (struct? k)
                                            (or (get k :as) (get k :alias))
                                            k)))))
                    (or (get s :cols) @[])))
            (defn unnamed-join-lacks? [x c]
              # walk the data path to the junction where a SELECT meets an
              # unnamed join, and refuse only where that select's published
              # projection lacks the name. Anything else below (group, append,
              # a resolvable join) is a different lane and never refused here.
              (if (not (struct? x))
                false
                (let [n (get x :node)]
                  (cond
                    (index-of n [:where :limit :order :distinct :query])
                    (unnamed-join-lacks? (or (get x :input) (get x :tree)) c)
                    (= :select n)
                    # a select that
                    # DECLARES a projection is determinable and is judged
                    # against it; a select that declares nothing (no :cols)
                    # is a pass-through - the engine decides and the
                    # ref defers. An absent list is an absent declaration,
                    # not a declared-empty one, so the empty case must not
                    # refuse (a cols-less select still executes and serves
                    # its input's names - refusing would be a false refusal,
                    # a false refusal of that class).
                    (and (not (empty? (or (get x :cols) @[])))
                         (not (projection-shows? x c))
                         (not (unnamed-join-key? (get x :input) c))
                         (unnamed-join-at? (get x :input)))
                    # the projection lane is a
                    # REFERENCE lane. Reaching an unnamed join through a lane
                    # this widening does not judge - a join's own keys, a
                    # co-operator's signal, a wrapping node - is not a
                    # published-projection verdict, so it defers as before
                    # (an unnamed arm's key name defers).
                    false))))
            (defn in-scope? [c]
              (def n* (near))
              (and n*
                   (not (nil? (find |(= (string (keyword (if (keyword? $) $ (keyword $))))
                                        (string (keyword c)))
                                    n*)))))
            # the QUALIFIER is the witness. An
            # alias-qualified reference names a column of THAT source, so it
            # is checked against the qualifier's own catalogued columns -
            # never against the row union (which let a column belonging to
            # another arm pass because the union carried the name somewhere).
            # Returns :in, :out, or nil (source unknown or uncatalogued -> defer)
            (defn arm-cols [a]
              # the columns an arm definitely EXPOSES: its own output
              # columns, or - when the arm is itself undeterminable - that
              # arm's own named sub-arms, conservatively unioned
              (or (local-outputs a)
                  # a pass-through arm exposes exactly
                  # what it passes through - look beneath it, otherwise a
                  # where between two joins hid the inner arm's columns
                  (when (and (struct? a)
                             (or (= :where (get a :node)) (= :limit (get a :node))
                                 (= :order (get a :node)) (= :distinct (get a :node))
                                 (= :select (get a :node))))
                    (arm-cols (get a :input)))
                  (when (and (struct? a) (or (get a :left) (get a :right)))
                    (def l (arm-cols (get a :left)))
                    (def r (arm-cols (get a :right)))
                    (when (and l r) (tuple ;(array/concat @[] l r))))))
            # a reference's column is NAMED by the catalogue anywhere: in any
            # column list the catalogue holds for any key. A shared metadata
            # block still counts here: this test answers "could some source
            # own the name", and the block is a statement about the file it
            # is attached to. The block discounts vacuous entries by
            # removing the SIBLING's entry from the arm's own judgement
            # (source-columns, target proof) - the cross-source check stays
            # a statement that some source may carry the column.
            (defn catalog-mentions? [c]
              (not (nil? (find |(= (string (keyword $)) (string (keyword c)))
                               (mapcat |(or (get $ :columns) @[])
                                       (map catalog (keys catalog)))))))
            (defn deferring-join-lacks? [x c]
              # walk down the data path to an undeterminable JOIN and ask
              # whether EVERY named arm lacks the column AND no catalogued
              # source anywhere mentions it - only then can the unnamed arm
              # not own it
              (cond
                (not (struct? x)) false
                (and (or (= :join (get x :node)) (= :asof (get x :node)))
                     (nil? (local-outputs x)))
                (let [l (arm-cols (get x :left))
                      nm (fn [k] (string (keyword k)))
                      keys-mention? (fn [c]
                                       (not (nil? (find |(= (nm $) (nm c))
                                                       (array/concat @[]
                                                                     (get x :lkeys)
                                                                     (get x :rkeys))))))]
                  (and l
                       (not (keys-mention? c))
                       (nil? (find |(= (string (keyword $)) (string (keyword c))) l))
                       (not (catalog-mentions? c))))
                (get x :input) (deferring-join-lacks? (get x :input) c)
                false))
            (defn qualifier-verdict [tab c]
              # G1: the qualifier's witness is its source's columns
              # by EVERY key the source answers to (r9 arms: the single-key
              # read made the caller's spelling decide the verdict)
              (when tab
                # `tab` is the qualifier as the caller spelled it; the
               # PARQUET PATH is what `key-of` resolves it to, and the
               # shared-block guard needs that path to recognise the arm's
               # own entry under the catalogue's spelling of it. Passing
               # the qualifier twice made an alias-qualified arm block
               # itself.
               (def cols (source-columns catalog key-of tab (get key-of tab) id-map))
                (when cols
                  (if (index-of (keyword c) cols) :in :out))))
            (defn qualifier-unknown? [tab]
              # the qualifier names no source the
              # catalog can describe (an unnamed parquet arm, an alias no
              # entry keys). It is a WITNESS THAT CANNOT ANSWER, never a
              # witness that refused - the lanes below must defer, not
              # refuse a reference the same tree serves without the
              # projection above it
              # G1: "cannot answer" is the shared resolver's
              # answer for EVERY key the source carries, not one key's
              (nil? (source-columns catalog key-of tab (get key-of tab) id-map)))
            # the node's own key slots: whose names stay OUTSIDE the name
            # check (documented known gap - this rule must not close it by accident)
            (def key-names @{})
            # a structured key is an expression: its column refs are
            # key-lane refs too and stay outside the name check
            (def key-structs @{})
            (each sl [(get t :keys) (get t :lkeys) (get t :rkeys)]
              (each k (or sl @[])
                (when (keyword? k) (put key-names (string (keyword k)) true))
                (when (struct? k) (put key-structs k true))))
            # join keys are checked PER SIDE - the left
            # key must name a column of the LEFT arm's output and the right
            # key of the RIGHT arm's. Under the merged-row model the row
            # carries both arms, so a key naming a column of neither arm (or
            # of the other arm only) would otherwise pass silently to the
            # engine. Only where both arms' outputs are known; an
            # undeterminable arm defers to the engine.
            (when (or (= :join (get t :node)) (= :asof (get t :node)))
              (def lout (local-outputs (get t :left)))
              (def rout (local-outputs (get t :right)))
              (defn in-out? [cols k]
                # the form is irrelevant - a string key
                # and a keyword key name the same column, so the (keyword? k)
                # gate goes and both forms are compared through their string
                # A two-state join row reads :known
                (def cs (if (and cols (has-key? cols :known))
                          (get cols :known)
                          cols))
                (and cs
                     (not (nil? (find |(= (string (keyword $)) (string (keyword k))) cs)))))
              (each k (or (get t :lkeys) @[])
                (when (and lout (not (in-out? lout k)))
                  (unknown-column! k)))
              (each k (or (get t :rkeys) @[])
                (when (and rout (not (in-out? rout k)))
                  (unknown-column! k)))
              # an arm whose own keys are all foreign is
              # REFUTED, not merely undeterminable, so its side's keys cannot
              # be vouched for and are refused rather than deferred into the
              # engine. `local-join-row` carries the marker.
              (when (= :foreign (local-join-row t))
                (each k (or (get t :lkeys) @[]) (unknown-column! k))
                (each k (or (get t :rkeys) @[]) (unknown-column! k))))
            (each ref (operator-refs t)
              (def deferred? (and (nil? (get ref 0)) (join-key-sentinel? (get ref 1))))
              (cond
                # an unqualified ref binds to the graph's sources; an
                # UNRESOLVED alias names a source nobody declared (the
                # check names it, tree-columns already carries it)
                (not (indexed? ref)) (array/push rows ref)
                # a row this node DEFERRED is not an
                # exemption - a postponed check stays a check where the
                # scope above is determinable. The computed-name exemption
                # (below) still runs FIRST: a name the node's own data path
                # produces needs no scope verdict (pass-through)
                (and deferred? (known-computed? t (get ref 2)))
                (do (drop-refs! t (get ref 2)) nil)
                (and deferred? (not (determinable))) (array/push rows ref)
                # GROUP ARGUMENT IS THE GROUP'S OWN
                # SCOPE. An aggregate's argument is resolved at the group,
                # against the group's INPUT - the group itself proves it
                # (group over a join expands fine). The row the group hands
                # on carries the KEYS and the COMPUTED names, never the
                # argument, so an ancestor re-judging the argument refuses
                # a column its own row legitimately dropped (the D-1/D-2
                # divergence: select(group(...)) refused :c). Only an
                # ARGUMENT is exempt: a group KEY is a genuine reference
                # the row check must still judge (r3R-fix1 pins it).
                (and (= :group n) (group-arg-col? t (get ref 2))
                     (in-row? (published-row (get t :input)) (get ref 2))
                     (supplied? (get t :input) (get ref 2)))
                (do (drop-refs!* t (get ref 2)) nil)
                # the computed-name exemption is SUBTREE-scoped (ruling 1A)
                # and runs BEFORE the projection guard: the referencing
                # node's own input must produce the name, and the matching
                # stored row is dropped, so every surviving row is a real
                # source reference (every-candidate or named-source decides those).
                #
                # The exemption is a PROOF claim, so it
                # follows the BARE declaration only. A named entry's name is
                # published by the node just beneath, so the proof must pass
                # through it like any other reference (supplied? does
                # exactly that); a rename over a row that lacks its source
                # is the launder - measured on stock: `(select (select join
                # (rename :b as z)) :z)` served :z over a row without :b.
                (and (known-computed? t (get ref 2)))
                (do (drop-refs! t (get ref 2)) nil)
                # a stored reference outside its own input's outputs is
                # refused HERE, where the scope is determinable: the row
                # would otherwise pass per-source strictness (the name IS
                # catalogued) and fail raw at the engine.
                # Narrowing only: a ref that IS in scope still faces the
                # per-source check below (input scope never WIDENS a lane).
                # Key lanes are excluded: join/asof keys stay outside the
                # name check entirely (a documented known gap that this rule must not close by accident).
                (and (not key-lane)
                     # the ceiling outranks the union. A
                     # publish anywhere beneath this reference decides the
                     # name, and that decision is final
                     (not (publishes? (get t :input)))
                     # a QUALIFIED ref is judged by
                     # its witness, never the row union - the union check
                     # would refuse a parquet-owned column above a join
                     (nil? (get ref 1))
                     (not (get key-names (string (keyword (get ref 2)))))
                     (not (get key-structs (get ref 4)))
                     (determinable)
                     (not (in-scope? (get ref 2))))
                (unknown-column! (get ref 2))
                # A QUALIFIED ref is judged by its witness, not
                # by the row union - :out refuses where the qualifier's own
                # source is catalogued and lacks the column; :in and an
                # unknown/uncatalogued qualifier fall through (defer)
                (and (get ref 1) (= :out (qualifier-verdict (or (get ref 0) (get ref 1)) (get ref 2))))
                (unknown-column! (get ref 2))
                # a qualifier whose source the
                # catalog DOES describe, and which carries the name, is a
                # proven witness - the reference settles here, before any
                # row lane can refuse it. Above a publishing select the
                # row is a CEILING for names the SELECTION surfaces, not
                # a veto on a source-qualified reference the witness
                # proves (that was the false refusal)
                (and (get ref 1) (= :in (qualifier-verdict (or (get ref 0) (get ref 1)) (get ref 2))))
                nil
                # The deferral is a POSTPONEMENT, never an
                # exemption. An operator above a deferred subtree re-emits
                # the reference; where the scope is undeterminable only
                # because a JOIN arm is unnamed, the name can still be
                # refused when NO arm supplies it - the unnamed arm cannot
                # conjure a name absent from every named arm's output and
                # from the catalogued arm's columns. (A name some arm may
                # really own still defers: the false-refusal rule wins.)
                # the clause runs AFTER the qualifier
                # witness so a qualifier's mention is judged by its source,
                # and carries the same guards (no key lane, no projection)
                # so the deferring shapes defer identically.
                # The clause carries the PROJECTION LANE
                # too, which judges refs unqualified AND qualified alike - the
                # projection is the whole row a selector above an
                # unnamed-join select sees, so a name it does not surface is
                # refused rather than handed to the engine.
                (and (not own-projection)
                     (not key-lane)
                     # a QUALIFIED ref naming an
                     # UNNAMED arm has no witness - the qualifier IS the
                     # proof and it cannot answer. Refusing it here was the
                     # false refusal the r6 probe Q2/Q3 pins: the same
                     # reference served BELOW this select, so publishing a
                     # projection must not narrow the engine-served set.
                     # The ref defers, exactly as the qualifier lane says
                     (not (and (get ref 1) (qualifier-unknown? (or (get ref 0) (get ref 1)))))
                     # the guard is about a JOIN KEY below a
                     # publish, never about an arbitrary reference: a where
                     # above a select still checks its predicate against
                     # that select's published row, while the
                     # key lane is judged at the join node
                     (not (unnamed-join-key? (get t :input) (get ref 2)))
                     (not (get key-names (string (keyword (get ref 2)))))
                     (not (get key-structs (get ref 4)))
                     # the published row is a THIRD witness beside the
                     # join-lacks test, and only a POSITIVE verdict refuses -
                     # :out (row lacks the name) and :noproof (row carries it
                     # with no proven supplier, the boundary rule). `:open`/nil
                     # (no row, or one nobody can decide) keeps the deferral,
                     # so the clause never refuses where the lane cannot answer
                     (index-of (published-lane (get t :input) (get ref 2))
                               [:out :noproof]))
                (unknown-column! (get ref 2))
                # column, so the input's own scope verdict decides; only an
                # input with no determinable scope lets the target through.
                # where the input publishes a row, that row
                # is a CEILING even against a target - the S2 launder is
                # this clause blessing a name the input's projection never
                # published. `determinable` is false
                # in exactly the case that matters, so the row check must
                # not depend on it, and an undeterminable input DEFERS.
                # Join-key SENTINELS are excluded (the key lane owns them); nothing else is, since a qualifier is not
                # machinery but the witness a name is resolved through
                (and own-projection
                     (not (join-key-sentinel? (get ref 1)))
                     (not (get key-structs (get ref 4)))
                     (let [lane (published-lane (get t :input) (get ref 2))]
                       (cond
                         # CR13 R2c: THE SELECT-TARGET
                         # CEILING. A select's TARGET is judged against the
                         # ROW ITS INPUT HANDS ON, and the published row is
                         # the boundary: :out (a name the row lacks) REFUSES
                         # whatever else the catalogue says, and a key slot
                         # does not lift it - the verifier reads the TARGET,
                         # never the key lane (2103, 1059). :in and :noproof
                         # serve past this clause as before (the chain lane
                         # below guards the :noproof launder).
                         # a row that CARRIES the name without proving
                         # it (a declared arm's row) is judged by the row and
                         # the name is not refused here - the row is the
                         # boundary; the declaration/proof artefact never
                         # decides. Only
                         # a row that LACKS the name refuses.
                         (= :out lane) true
                         # no carrier: no row (:none), an unreadable one
                         # (:open), or a row carrying the name with no proof
                         # (:noproof). Defer to the engine unless the scope
                         # is determinable and lacks the name
                         (and (nil? (index-of lane [:in :noproof]))
                              (determinable) (not (in-scope? (get ref 2))))
                         true false)))
                (unknown-column! (get ref 2))
                # the echo also
                # vouches where the input's row lexically CARRIES the name
                # (:noproof) - a declared arm re-exposes what its own
                # declaration holds, and the row is the boundary. The proof
                # obligation sits at the node that DECLARES, not at every
                # consumer of the declaration (defer-to-the-arm).
                (and own-projection
                     (= :noproof (published-lane (get t :input) (get ref 2)))
                     (in-row? (published-row (get t :input)) (get ref 2)))
                nil
                # a select's own TARGET re-exposes a column of its input;
                # it is not a stored reference made by this node. The
                # echo vouches only for a name the input PROVES (:in),
                # or one it cannot judge - publishing anything else is the
                # launder itself. Totality: a name the lane
                # does not positively serve falls through to refusal
                (and own-projection
                     (= :in (published-lane (get t :input) (get ref 2)))
                     (some (fn [c]
                             (= (string (keyword (get ref 2)))
                                (string (keyword (if (struct? c)
                                                   (or (get c :col) (get c :as) (get c :alias))
                                                   c)))))
                           (get t :cols)))
                nil
                (and (nil? (get ref 0)) (get ref 1)) (array/push rows ref)
                nil))
            (walk-refs (get t :input))
            (when (get t :sides) (each s (get t :sides) (walk-refs s)))
            (when (get t :left) (walk-refs (get t :left)))
            (when (get t :right) (walk-refs (get t :right))))))))
    (walk-refs tree*)
    # a bound unqualified row carries its source keys only once the walk is
    # done: the operator that emitted it can sit BELOW a source declaration
    (each r rows
      (when (and (indexed? r) (= 5 (length r)) (nil? (r 0)) (nil? (r 1)))
        (put r 4 (sort (keys key-of)))))
    (defn row-sources [row]
      # element 3 is the catalog key the emitting operator resolved (the
      # source's own key, never an alias); element 0 is whatever the
      # operator recorded and may be an alias - prefer the resolved key
      (def rcat (when (> (length row) 3) (row 3)))
      (def tab (row 0))
      (def key (or rcat (when (and tab (has-key? key-of tab)) tab)))
      (array/concat @[]
                    (if (= :u tab) (sort (keys key-of)) @[])
                    (if key @[key] @[])))
    (defn row-catalogued? [row]
      (var ok true)
      (def srcs (row-sources row))
      (for i 0 (length srcs)
        (def k (srcs i))
        (unless (not (nil? (source-catalogued? catalog key-of k nil id-map)))
          (set ok false)))
      ok)
    # a reference that names a column PRODUCED beneath it (an aggregate
    # alias, a select expression name) is not a source reference: the
    # catalog has nothing to say about it. The test
    # is the node's own OUTPUT columns, never the tree's - the projection
    # list of a select echoes whatever it was given and would exempt every
    # name. A STORED reference stays per-source strict
    # (every-candidate or named-source).
    (defn src-key-known? [k]
      # a source answers to the key the CALLER catalogued
      # it under and to the key it resolves to. Looking up only the resolved
      # key made an alias-keyed entry vanish behind the path (and vice versa),
      # so which spelling the catalog used decided a verdict - the catalogue
      # must decide membership only
      # R2: the catalogue decides WHICH COLUMNS a source
      # contributes, never whether its verdict is deferred or refused - the
      # question asked here is "does an entry DESCRIBE this source", and an
      # entry describing nothing (irrelevant path, shared block, closed
      # wall) answers nil exactly as an absent entry does
      (not (nil? (source-catalogued? catalog key-of k nil id-map))))
    (defn all-catalogued? []
      (var ok true)
      (each k (sort (keys key-of))
        (unless (src-key-known? k) (set ok false)))
      ok)
    (each row rows
      (when (indexed? row)
       (def tab (row 0))
      (def alias (when (> (length row) 1) (row 1)))
      (def c (row 2))
      (def ck (keyword c))
      (def cat-key (when (> (length row) 3) (row 3)))
      (def bound-by (when (and (nil? tab) (nil? alias) (> (length row) 4)) (row 4)))
      (when (and (nil? tab) alias (not (join-key-sentinel? alias))
                 (not (has-key? key-of alias)))
        (unknown-column! alias))
      (def self-row (array/new 5))
      (array/push self-row tab) (array/push self-row alias)
      (array/push self-row c) (array/push self-row cat-key) (array/push self-row bound-by)
      (def ref-rows
        (if bound-by [row]
            (if (and (nil? tab) (nil? alias))
              (seq [r* :in rows :when (= :u (r* 0))] r*)
              # an array, never a literal tuple: a 5-slot tuple read back
              # through index 0 is a METHOD CALL in janet (a 3-slot tuple is
              # not), so the row must be the mutable shape the rest of the
              # check already consumes
              [self-row])))
      (each row* ref-rows
        (def rtab (row* 0))
        (def rcat (row* 3))
        # Every-candidate or named-source: an UNQUALIFIED
        # reference is satisfied when ANY candidate source has the column,
        # so the check is per-CANDIDATE and the first hit ends it.
        (def unb (and (nil? alias) (nil? tab)))
        (def ks
          (when (and (not (nil? rtab))
                     (not (nil? (source-catalogued? catalog key-of rcat nil id-map)))
                     (row-catalogued? row*))
            (src-known rcat)))
        # walk-refs already exempted the names a reference's own input
        # produces (ruling 1A): every row here is a STORED reference, so it
        # is checked per source (every-candidate or named-source)
        (if unb
          # collect every candidate's verdict; the row survives on one hit,
          # defers when a candidate is uncatalogued, and only refuses when
          # EVERY catalogued candidate lacks the name
          (do
            (var hit false)
            (var pend false)
            (each r2 ref-rows
              (def r2cat (r2 3))
              (def k2 (when (and (not (nil? (r2 0)))
                                 (not (nil? (source-catalogued? catalog key-of r2cat nil id-map)))
                                 (row-catalogued? r2))
                        (src-known r2cat)))
              (cond
                (nil? k2) (set pend true)
                (index-of ck k2) (set hit true)))
            (unless (or hit pend)
              (unknown-column! c)))
          (when (and ks (not (index-of ck ks)))
            # A reference is judged against the ROW ITS INPUT PRODUCES, not the
            # source its binding records. Above a join that row is the UNION
            # of both arms. Pass-through operators (where/limit/order/
            # distinct/query) do not reshape, so the witness walks THROUGH
            # them to the nearest reshaping operator. The witness is that
            # operator's outputs, never this node's own projection, so a
            # select echo is not a scope. An undeterminable witness keeps
            # the per-source verdict.
            (defn reshape-witness [x]
              (if (not (struct? x))
                nil
                (let [n (get x :node)]
                  (cond
                    (or (= :join n) (= :asof n))
                    # ask the JOIN for its own row, the
                    # same union rule output-columns* applies. Reading each
                    # arm's own output made a parquet arm nil (its columns are
                    # the catalog's business, not the arm's), so the union was
                    # nil and the catalog key that spelled the arm decided the
                    # verdict. One rule, one answer, whichever key the caller
                    # catalogued under
                    #
                    # the union must not stand in for
                    # an ARM. A union is a statement about the join, never
                    # about one source in it, so an arm whose own entries do
                    # not describe it stays UNNAMED and the reference defers
                    # (the pre-fix answer for an uncatalogued arm). Reading
                    # the union as the arm's row let a sibling carrying the
                    # name testify for a source that never catalogued it.
                    (local-join-row x)
                    # an append's row IS the positional
                    # alignment output-columns* computes - the same union
                    # rule near applies, so the two lanes cannot disagree.
                    (and (struct? x) (get x :sides))
                    (local-outputs x)
                    # a group RESHAPES: its output row is its keys plus its
                    # aggregate entries, so a selector above it is checked
                    # against exactly that. A key that
                    # the group's own input does not produce is not a real
                    # output: a regression test refuses it here.
                    (= :group n)
                    (let [ks (map (fn [k] (if (struct? k) (get k :col) k))
                                  (or (get x :keys) @[]))
                          comp (computed-outputs x)
                          inw (reshape-witness (or (get x :input) (get x :tree)))]
                      (tuple ;(array/concat @[]
                                            (if inw
                                              (seq [k :in ks
                                                    :when (not (nil? (find |(= (string (keyword $))
                                                                               (string (keyword k)))
                                                                           inw)))]
                                                k)
                                              @[])
                                            (map |(symbol (string $)) (keys comp)))))
                    # a pass-through does not reshape: walk to the nearest
                    # reshaping operator through ANY of them, not a fixed
                    # five. A GROUP is not walked through: its own scope is
                    # its own business and returning its keys as a witness
                    # let a key cross the group.
                    (or (= :where n) (= :limit n) (= :order n)
                        (= :distinct n) (= :query n)
                        # a select above a select is
                        # transparent to the scope question - its own column
                        # list is a projection, not a scope, so the witness
                        # stays the reshaping operator below (the echo
                        # exemption itself is untouched)
                        (= :select n))
                    (reshape-witness (or (get x :input) (get x :tree)))
                    nil))))
            (def reshaped (when (nil? alias)
                            (reshape-witness (or (get tree* :input) (get tree* :tree)))))
            (unless (or (and reshaped
                             (not (nil? (find |(= (string (keyword $)) (string ck)) reshaped))))
                        (and (nil? alias) (not (all-catalogued?)))
                        # R2 (the select passthrough): a
                        # select that declares nothing is a pass-through and
                        # the engine decides. The ceiling above
                        # stands on the row's STORED source columns, not on
                        # the catalogue: an arm nobody described defers the
                        # name exactly as an uncatalogued arm does, and a
                        # declare-nothing select above it never turns the
                        # deferral into a serve.
                        # R2b (D1): a select that declares nothing publishes
                        # no row of its own, so its name check walks THROUGH
                        # it to the nearest row-producing node (a declared
                        # projection, a group, a join, an append, a source
                        # arm) and refuses only a name that row lacks: a
                        # projection is a refusal BOUNDARY, never an
                        # existence proof, and the source row is not a
                        # boundary a pass-through holds
                        # (projectionRefusalIsPublished)
                        (and (empty? (or (get tree* :cols) @[]))
                             (nil? (let [pub (fn pub [e]
                                               (cond
                                                 (not (struct? e)) nil
                                                 (= :select (get e :node))
                                                 (if (empty? (or (get e :cols) @[]))
                                                   (pub (get e :input))
                                                   (output-columns* key-of e catalog @{} id-map))
                                                 (= :from (get e :node))
                                                 (let [tab (if (keyword? (get e :src)) (get e :src)
                                                             (when (string? (get e :src)) (keyword (get e :src))))]
                                                   (when-let [ks (source-columns catalog key-of tab nil id-map)]
                                                     (tuple ;ks)))
                                                 true (output-columns* key-of e catalog @{} id-map)))]
                                     (pub tree*)))))
              (unknown-column! c))))))))
  (put rec :node-types (tuple ;(node-types-of tree*)))
  (table/to-struct
    (merge rec {:columns (output-columns tree* catalog)})))

#==------------------------------------------------------------------------==#
# count-distinct expansion (the two-graph composition)
#==------------------------------------------------------------------------==#

(defn/typed expand-count-distinct {:args [:any] :ret :struct}
  [tree]
  "Rewrite group nodes whose aggregates are exclusively
count-distinct into the two-graph composition: distinct over
(keys + col), then grouped count(col). Used when the selected
backend's matrix declares :count-distinct :expansion. A group mixing
count-distinct with other aggregates is a v1 boundary (not in the
ratified composition) - raises malformed-tree naming the group."
  # memo by IDENTITY: a shared child is rewritten once, so a diamond
  # of shared subtrees costs one node per distinct object instead of 2^depth
  (def memo @{})
  (var rewrite nil)
  (defn rewrite* [t]
    (do
      (let [t (if (= :query (get t :node))
                (table/to-struct (merge t {:tree (rewrite (get t :tree))}))
                t)
            n (get t :node)]
        (cond
          (and (= n :group)
               (or (get t :input) (get t :sides) (get t :left) (get t :right))
               (some |(and (struct? $0) (= :count-distinct (get $0 :agg)))
                     (get t :aggs)))
          (let [t (table/to-struct
                    (merge t
                      (if (get t :input) {:input (rewrite (get t :input))} {})
                      (if (get t :sides) {:sides (tuple ;(map rewrite (get t :sides)))} {})
                      (if (get t :left) {:left (rewrite (get t :left))} {})
                      (if (get t :right) {:right (rewrite (get t :right))} {})))]
            (when (some |(not= :count-distinct (get $0 :agg)) (get t :aggs))
              (err :malformed-tree {:node t :why :mixed-count-distinct}))
            (def gkeys (get t :keys))
            (def cd-cols (map (fn [a] (get (get a :arg) :col)) (get t :aggs)))
            (def distinct-cols (uniq (tuple ;gkeys ;cd-cols)))
            (def proj {:node :select :cols distinct-cols :input (get t :input)})
            (def dist {:node :distinct :input proj})
            {:node :group :keys (tuple ;gkeys)
             :aggs (tuple ;(map (fn [c] {:expr :agg :agg :count
                                          :arg {:expr :get :col c :alias nil}})
                                cd-cols))
             :input dist})
          :else
          (table/to-struct
            (merge t
              (if (get t :input) {:input (rewrite (get t :input))} {})
              (if (get t :sides) {:sides (tuple ;(map rewrite (get t :sides)))} {})
              (if (get t :left) {:left (rewrite (get t :left))} {})
              (if (get t :right) {:right (rewrite (get t :right))} {})))))))
  (set rewrite (fn [t]
                (if (not (struct? t)) t
                  (or (get memo t)
                      (let [r (rewrite* t)]
                        (put memo t r)
                        r)))))
  (def out (rewrite tree))
  (if (struct? out) out (table/to-struct out)))

#==------------------------------------------------------------------------==#
# Backend registration (contract 4.1)
#==------------------------------------------------------------------------==#

(def backends @{})

(defn/typed require-keys {:args [:any] :ret nil} [reg]
  (each k [:name :renderer :execute :catalog-spec :matrix]
    (unless (get reg k)
      (err :registration {:kind :missing-key :key k :backend (get reg :name)})))
  (unless (keyword? (get reg :name))
    (err :registration {:kind :name-type :backend (get reg :name)}))
  (unless (function? (get reg :renderer))
    (err :registration {:kind :renderer-not-function :backend (get reg :name)}))
  (unless (function? (get reg :execute))
    (err :registration {:kind :execute-not-function :backend (get reg :name)}))
  (unless (or (struct? (get reg :matrix)) (table? (get reg :matrix)))
    (err :registration {:kind :matrix-type :backend (get reg :name)}))
  nil)

(defn/typed validate-matrix {:args [:keyword :any] :ret :nil}
  [name matrix]
  "Matrix well-formedness (the qnt init conditions): every key a
known node type, every shared operator declared. Raises the
registration error class naming the offending entry."
  (each [op mode] (pairs matrix)
    (unless (index-of op known-ops)
      (err :registration {:kind :malformed-matrix :operator op :backend name}))
    (unless (keyword? mode)
      (err :registration {:kind :malformed-matrix :operator op :backend name})))
  (each op shared-ops
    (unless (get matrix op)
      (err :registration {:kind :shared-op-undeclared :operator op :backend name})))
  nil)

(defn/typed register-backend! {:args [:any] :ret :nil}
  [reg]
  "Register a backend (contract 4.1): {:name :renderer :execute
:catalog-spec :matrix}. The seam enforces the section 2 wrapper shape on
every execute return (see core-seam-result)."
  (require-keys reg)
  (def name (get reg :name))
  (when (get backends name)
    (err :registration {:kind :duplicate-name :backend name}))
  (validate-matrix name (get reg :matrix))
  # runtime mirror of the qnt matrixWellFormed invariant re-checked on
  # every registration that follows (a later registration must not
  # leave an earlier matrix inconsistent with the shared set)
  (each [b prior] (pairs backends)
    (each op shared-ops
      (unless (get (get prior :matrix) op)
        (err :registration {:kind :shared-op-undeclared :operator op
                            :backend b}))))
  (put backends name (table/to-struct reg))
  nil)

#==------------------------------------------------------------------------==#
# Selection, denial, the pipeline (contract 4.2/4.3; qnt (a)-(e))
#==------------------------------------------------------------------------==#

(defn/typed select-backend {:args [:any :any] :ret :keyword}
  [explicit provenance-set]
  "Backend selection precedence (contract 4.3 - no default, ever):
 explicit :backend, else handle provenance, else :backend-ambiguous.
 An explicit backend must be registered. A provenance backend that is
 not registered is user-authored data naming a backend nobody
 registered: {:error :unknown-backend :backend <b>} (never :internal). Explicit vs provenance disagreement raises
 :backend-conflict BEFORE any expansion (qnt property (e): conflict
 never executes)."
  # an explicit backend must be a registered one; a provenance backend
  # the tree names must be too (user-authored data)
  (when explicit
    (unless (get backends explicit) (err :unknown-backend {:backend explicit})))
  (each b provenance-set
    (unless (get backends b) (err :unknown-backend {:backend b})))
  (def inferred
    (cond
      (empty? provenance-set) nil
      (= 1 (length provenance-set)) (provenance-set 0)
      # multi-valued provenance (all registered): nothing infers
      nil))
  (cond
    (and explicit inferred (not= explicit inferred))
    (err :backend-conflict {:explicit explicit :inferred inferred})
    (or explicit inferred)
    (or explicit inferred)
    (err :backend-ambiguous {})))

(defn/typed deny-check {:args [:any :any :any] :ret :nil}
  [tree expanded reg]
  "The intersection-rule runtime assertions (qnt properties (a)-(c)):
a shared node is never denied (registration guarantees the matrix
declares it - re-asserted here), an extension node the backend does
not declare is ALWAYS denied with operator and backend named, and
denial happens in this pass - before any render or execute call."
  (def name (get reg :name))
  (def matrix (get reg :matrix))
  (def types (get expanded :node-types))
  # (a) shared never denied: matrix must carry every shared op
  (each op shared-ops
    (unless (get matrix op)
      (err :internal {:kind :shared-op-missing :operator op :backend name})))
  (each op types
    (when (and (not (index-of op shared-ops)) (not (get matrix op)))
      (err :extension-denied {:operator op :backend name})))
  # escape nodes: tag must match the selected backend, matrix entry
  # or not (contract 3.4: non-portable by construction)
  (defn walk-escape [t]
    (when (struct? t)
      (when (= :escape (get t :node))
        (unless (= (get t :backend) name)
          (err :extension-denied {:operator :escape :backend name})))
      (each k [:pred :arg]
        (when (struct? (get t k)) (walk-escape (get t k))))
      (when (indexed? (get t :args)) (each a (get t :args) (walk-escape a)))
      (when (indexed? (get t :keys))
        (each k (get t :keys) (when (struct? k) (walk-escape k))))
      (when (indexed? (get t :cols))
        (each c (get t :cols) (when (struct? c) (walk-escape c))))
      (when (indexed? (get t :aggs)) (each a (get t :aggs) (walk-escape a)))
      (walk-escape (get t :input))
      (when (get t :sides) (each s (get t :sides) (walk-escape s)))
      (when (get t :left) (walk-escape (get t :left)))
      (when (get t :right) (walk-escape (get t :right)))))
  (walk-escape tree)
  # count-distinct expansion strategy is a backend-declared matrix
  # decision, never hardcoded
  (def cd (get matrix :count-distinct))
  (when (and (index-of :count-distinct types) (= :expansion cd))
    (err :internal {:kind :expansion-not-applied :backend name}))
  nil)

(defn/typed pick-catalog {:args [:any] :ret :any}
  [c]
  "nil-safe catalog selection: an absent or EMPTY catalog means no
name checks (the engine is the only validator) - empty
tables are truthy in janet."
  (if (or (nil? c) (empty? c)) nil c))

(defn/typed prepare {:args [:any :any :any] :ret :struct}
  [q backend catalog]
  "The pipeline: unwrap, selection (before expansion), the tree pass
(malformed + catalog name checks), denial (before any render), the
count-distinct expansion strategy. Returns {:tree :expanded :reg}."
  (def tree (if (and (struct? q) (= :query (get q :node))) (get q :tree) q))
  # cross-backend guard FIRST: a tree built from handles of two distinct
  # backends is refused where it is composed, before selection
  (guard-cross-backend q)
  (def provenance (collect-sources q))
  (def selected (select-backend backend provenance))
  (def reg (get backends selected))
  (unless reg
    (err :unknown-backend {:backend selected}))
  # one class per disagreement (contract 4.3 v0.5): an explicit backend
  # over a tree whose HANDLE sources name no backend is the ambiguity,
  # not a tree defect - selection owns it, expansion never sees it. A
  # table/parquet source carries no handle provenance by design and is
  # not ambiguous.
  (when (and backend (empty? provenance) (handle-without-backend? q))
    (err :backend-ambiguous {}))
  (def cat (pick-catalog (or catalog (get reg :catalog-spec))))
  (def expanded (expand-tree tree cat))
  (def frozen (get expanded :tree))
  (def matrix (get reg :matrix))
  (def tree*
    (if (and (index-of :count-distinct (get expanded :node-types))
             (= :expansion (get matrix :count-distinct)))
      (expand-count-distinct frozen)
      frozen))
  (def expanded* (if (not= tree* frozen) (expand-tree tree* cat) expanded))
  (deny-check tree* expanded* reg)
  {:tree tree* :expanded expanded* :reg reg})

# exception: varargs + key parsing - the raise carries the malformed class, not a guard
(defn parse-opts
  "Keyword varargs -> struct (:backend :catalog recognised; any other
key is a named error - the option set is contract-stated, extras are
not added silently)."
  [& args]
  (def opts (parse-kw-args ;args))
  (each k (keys opts)
    (unless (index-of k [:backend :catalog])
      (err :malformed-tree {:node {:option k} :why :unknown-option})))
  opts)

# exception: optional :backend keyword - &opt arity
(defn render
  "Render a query on one backend (contract 3.1: backend-less render
is meaningless - the same selection rule as execute, no execution).
Returns the backend's engine form (for duckdb: {:sql :params})."
  [q & args]
  (def opts (parse-opts ;args))
  (def p (prepare q (get opts :backend) (get opts :catalog)))
  ((get (get p :reg) :renderer) (get p :tree)))

# exception: &opt arity - fixed-arity defn/typed cannot express it.
(defn wrap-result [rows columns &opt backend]
  "The ONE result shape (contract section 2): :rows a vector of rows,
each row a positional TUPLE aligned to :columns (ratified ruling 1A -
tuples are the shape both shipped backends deliver); column order is
observable only via :columns."
  (unless (or (array? rows) (tuple? rows))
    (err :internal {:kind :bad-rows}))
  (unless (or (array? columns) (tuple? columns))
    (err :internal {:kind :bad-columns}))
  # a row is positional (ruling 1A): every row must be an array or tuple,
  # refused HERE so a scalar row never reaches the conversion below, where
  # janet's raw "expected array or tuple" would escape the error grammar
  #
  (each r rows
    (unless (or (array? r) (tuple? r))
      (err :internal {:kind :bad-result-shape :row r :backend backend})))
  @{:rows (seq [r :in rows] (if (tuple? r) r (tuple ;r)))
    :columns (if (array? columns) columns @[;columns])})

(defn/typed core-seam-result {:args [:any :any] :ret :table} [res reg]
  "The core seam (contract section 2 v0.5): whatever a registered
backend's execute returns is validated and normalised HERE, so the
section 2 wrapper is the result form BY CONSTRUCTION, not by backend
convention. A backend hands over {:rows <seq> :columns <seq>}
(normalised through wrap-result). A result of neither shape - a bare
value, a table missing a key, rows that are not a sequence - raises the
internal bad-result-shape class instead of surfacing the backend's raw
value."
  (if (and (dictionary? res) (indexed? (get res :rows))
           (indexed? (get res :columns)))
    (wrap-result (get res :rows) (get res :columns) (get reg :name))
    (err :internal {:kind :bad-result-shape :backend (get reg :name)})))

# exception: optional :backend keyword - &opt arity
(defn execute
  "Execute a query on one backend (contract sections 2, 4.3).
Returns the single result wrapper {:rows @[...] :columns [...]}."
  [q & args]
  (def opts (parse-opts ;args))
  (def p (prepare q (get opts :backend) (get opts :catalog)))
  (def reg (get p :reg))
  (core-seam-result ((get reg :execute) ((get reg :renderer) (get p :tree))) reg))

#==------------------------------------------------------------------------==#
# The coverage manifest (contract section 7: data, shipped with the module)
#==------------------------------------------------------------------------==#

(def coverage-manifest
  "operator x edge-class per backend -> the test cell id that covers
it. Backends merge their rows at registration-side import; slice 4's
completeness gate reads this table."
  @{})

(defn/typed add-manifest! {:args [:keyword :any] :ret :nil}
  [backend rows]
  "Backend module helper: merge manifest rows (op|edge -> cell id)."
  (def tbl (or (get coverage-manifest backend) @{}))
  (each [k v] (pairs rows) (put tbl k v))
  (put coverage-manifest backend tbl)
  nil)

# constructor function values for the defquery scope - a STATIC table
# (direct value references, no env lookups) because ten constructor
# names shadow core bindings (get count first last min max distinct
# div mod var) and are defined under internal names, exported at the
# file end AFTER everything that compiles against core get
(def ctor-fns
  @{'from from 'where where 'join join 'group group 'select select
    'order order 'limit limit 'distinct node-distinct 'append append
    'from-parquet from-parquet 'write-parquet write-parquet
    'escape escape 'window window 'pivot pivot
    'lit lit 'get col2 'add add 'sub sub 'mul mul 'div divx
    'idiv idiv 'mod modx 'eq eq 'ne ne 'lt lt 'le le 'gt gt
    'ge ge 'and2 and2 'or2 or2 'not2 not2 'isnull isnull
    'min2 min2 'max2 max2 'if2 if2 'in in 'not-in not-in
    'sum sum 'avg avg 'count agg-count 'count-distinct count-distinct
    'min agg-min 'max agg-max 'first agg-first 'last agg-last
    'stddev stddev 'var agg-var 'median median})

#==------------------------------------------------------------------------==#
# defquery (DSL surface 5: bare constructors, tree-based validation)
#==------------------------------------------------------------------------==#

(defn/typed collect-bindings {:args [:any] :ret :array}
  [form]
  "Symbols bound by the binding forms of an unevaluated body (let,
fn/defn params, def/var, each/for/loop, if-let/when-let, with)."
  (def out @[])
  (defn binding-syms [b]
    (cond
      (symbol? b) (array/push out b)
      (tuple? b) (each x b (when (symbol? x) (array/push out x)))
      (array? b) (each x b (when (symbol? x) (array/push out x)))
      (struct? b) (eachp [k v] b (when (symbol? k) (array/push out k)))
      nil))
  (defn walk [f]
    (when (tuple? f)
      (def head (first f))
      (cond
        (index-of head ['let 'with 'if-let 'when-let])
        (do (binding-syms (f 1)) (each x (tuple/slice f 2) (walk x)))
        (= 'fn head)
        (do (when (tuple? (f 1)) (binding-syms (f 1)))
            (each x (tuple/slice f 2) (walk x)))
        (index-of head ['def 'defn 'defn- 'defmacro 'var 'def- 'varglobal 'defglobal])
        (do (when (symbol? (f 1)) (array/push out (f 1)))
            (when (and (> (length f) 2) (tuple? (f 2)))
              (binding-syms (f 2)))
            (each x (tuple/slice f 2) (walk x)))
        (index-of head ['each 'eachp 'for 'loop 'generate])
        (do (binding-syms (f 1)) (each x (tuple/slice f 2) (walk x)))
        (each x (tuple/slice f 1) (walk x))))
    (when (array? f) (each x f (walk x))))
  (walk form)
  out)

(defn/typed attach-meta {:args [:string :any] :ret :struct}
  [name tree]
  "Wrap a composed tree as a named query with its expansion metadata
attached (defquery runs the tree pass at expansion; the manifest is
data on the value). A struct - the wrapper is an inert value like
every node."
  (def expanded (expand-tree tree))
  {:node :query :name name :tree tree
   :manifest (get expanded :node-types)})

(defmacro defquery
  "Define a named query with bare constructor scope (DSL surface 5):
(defquery spent (from :invoices) (group [:customerid] (sum (get
:total)))) threads the body forms through ->. Shadowing a constructor
name with a binding (a let-bound or parameter name) raises a clear
expansion error listing the offending name. Dynamic composition via
the prefixed constructors produces the same tree - validation is
tree-based, not macro-based."
  [name & body]
  (each b body
    (each s (collect-bindings b)
      (when (index-of s ctor-names)
        # compile-time lane: a clear string diagnostic (the struct error
        # grammar is the runtime execute/render lane; a macro raise is
        # wrapped by the compiler, so the string carries the facts)
        (errorf "defquery-shadowing: %s shadows a constructor - rename the binding"
                s))))
  # constructor function values captured from THIS module's env at
  # macro-expansion time - the expansion embeds the values, no module
  # path lookup at user runtime (definitions precede this macro)
  (def bindings
    (seq [c :in ctor-names]
      [c (get ctor-fns c)]))
  (def inner (if (= 1 (length body)) (first body) (tuple '-> ;body)))
  # attach-meta spliced as a VALUE (module-private from the user env);
  # the bare-constructor scope is the query expression ONLY (a let
  # around the threaded composition - standard janet scoping, no
  # magic, DSL surface 5.3; the surrounding file keeps its bindings)
  ~(def ,name
     (,attach-meta ,(string name)
                   (let [,;(mapcat identity bindings)] ,inner))))

# core-shadowing constructors export LAST: everything above compiled
# against core get/count/first/last/min/max/distinct/div/mod/var; the
# env puts below are the only place the public names enter the module
# env (importers and the defquery scope see the constructors, the
# module body never did). Entries are wrapped {:value f} - import's
# merge-module reads entries by shape, a bare fn value breaks it
(put (curenv) 'get @{:value col2})
(put (curenv) 'count @{:value agg-count})
(put (curenv) 'first @{:value agg-first})
(put (curenv) 'last @{:value agg-last})
(put (curenv) 'min @{:value agg-min})
(put (curenv) 'max @{:value agg-max})
(put (curenv) 'distinct @{:value node-distinct})
(put (curenv) 'div @{:value divx})
(put (curenv) 'mod @{:value modx})
(put (curenv) 'var @{:value agg-var})

