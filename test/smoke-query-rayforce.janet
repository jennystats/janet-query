# smoke-query-rayforce - the rayforce backend conformance smoke. Cell
# classes: every SERVED operator (the served surface),
# the two alignment fences (the raw module's misaligned
# shapes first, then the backend fence), the denial matrix rows, the
# leak tier (ray_mem_trace net-0 per translate-execute-decode cycle)
# and the first-pass dual-backend equivalence cells for the shared
# surface. Requires librayforce (SKIP if
# absent - present-but-broken is a FAIL).
#
# Cell ids name the coverage-manifest rows seeded in query-rayforce.janet.
(import jennystats/query :prefix "jq/")
(import jennystats/query-rayforce :as rfq)
(import jennystats/query-duckdb :as jqd)
(import jennystats/rayforce :as rf)
(import jennystats/duckdb :as duckdb)

(defn assert-eq [a b msg]
  (unless (deep= a b) (errorf "FAIL %s: %q != %q" msg a b)))

(defn catch-err [f]
  (var c nil)
  (try (f) ([e] (set c e)))
  c)

(defn assert-err [f want msg]
  (assert-eq (catch-err f) want msg))

(defn assert-err-match [f pat msg]
  (def e (catch-err f))
  (unless (and e (string/find pat (string e)))
    (errorf "FAIL %s: expected a raise matching %q, got %q" msg pat e)))

(defn rows-sorted [wrapper]
  "Rows as a sorted multiset key (unordered-query comparison, contract 6)."
  (sorted (map (fn [r] (string ;(map |(string $0 " ") r))) (get wrapper :rows))))

(defn rows-close [a b tol]
  "Tolerant row comparison (floating lanes): exact for nil/strings,
  relative tolerance for numbers - the first-pass equivalence rule
  (slice 4's harness pins the constant; 1e-12 here)."
  (and (= (length a) (length b))
       (all (fn [i]
              (def x (a i))
              (def y (b i))
              (cond
                (and (nil? x) (nil? y)) true
                (and (number? x) (number? y))
                (<= (math/abs (- x y)) (* tol (max (math/abs x) 1)))
                (deep= x y)))
            (range (length a)))))

(defn ex [q] (jq/execute q :backend :rayforce))

(def ds @{:backend :rayforce
          :columns @[@["id" @[1 2 3 4]]
                     @["dept" @[1 1 2 nil]]
                     @["pay" @[1.5 2.5 3.5 4.5]]]})

# == the two alignment fences ================================================
# Pre-fence observation 1: the RAW module's misaligned group agg is
# SILENTLY wrong (a 2-row agg column over 3 groups folds to @[0 0 1],
# exit 0 - the engine folds the short column; the module does not
# fence it). The module is UNCHANGED - this cell
# re-observes it through the published surface.
(do
  (def t (rf/table-from-columns @{:id @[1 2 3 4] :dept @[1 1 2 nil]}))
  (def g (rf/graph t))
  (def t2 (rf/table-from-columns @{:x @[1.0 2.0]}))
  (def tid (rf/add-table g t2))
  (def res (rf/execute g (rf/group g [(rf/scan g "dept")]
                                     [[(rf/scan-table g tid "x") :sum]])))
  (assert-eq (get (rf/table-columns res) "x_sum") @[0 0 1]
             "fence-agg|pre-fence raw-module misaligned agg is
silently wrong (the raw-module observation)")
  (:close res) (:close g) (:close t2) (:close t))

# Pre-fence observation 2: the misaligned filter pred raises ENGINE-side
# at execute (after plan-build), typed - the backend fence moves the
# class to translation, before any engine call.
(do
  (def t (rf/table-from-columns @{:id @[1 2 3 4]}))
  (def g (rf/graph t))
  (def t2 (rf/table-from-columns @{:x @[1.0 2.0]}))
  (def tid (rf/add-table g t2))
  (assert-err-match
    (fn [] (rf/execute g (rf/filter g (rf/const-table g t)
                                     (rf/lt g (rf/scan-table g tid "x")
                                            (rf/const-f64 g 2.0)))))
    "mask length"
    "fence-pred|pre-fence raw-module misaligned pred raises at
execute (the raw-module observation)")
  (:close g) (:close t2) (:close t))

# Fence 1 post-fence: a where pred column outside the output scope
# raises the malformed-tree class BEFORE any engine call
(assert-err
  (fn [] (ex (jq/where (jq/from ds) (jq/lt (jq/get :nope) (jq/lit 1)))))
  {:error :malformed-tree :why :filter-pred-row-scope :name "nope"
   :node {:expr :get :col :nope :alias nil} :backend :rayforce}
  "fence-pred|fence 1 raises the class before any engine call")
# a where referencing a column dropped by the projection stays
# row-aligned (select preserves rows; the predicate is equivalent to a
# pushdown below it - probe-verified through the raw module)
(assert-eq (ex (jq/where (jq/select (jq/from ds) :id :pay)
                         (jq/lt (jq/get :dept) (jq/lit 2))))
           @{:columns @[:id :pay] :rows @[[1 1.5] [2 2.5] [4 4.5]]}
           "fence-pred|pred over a projection-dropped column is
row-aligned (select preserves rows); the nil-dept row is KEPT - the
two-valued lt lane, not an alignment failure")

# Fence 2 post-fence: a group agg input / key outside the scope
(assert-err
  (fn [] (ex (jq/select (jq/group (jq/from ds) [:dept] (jq/sum (jq/get :nope)))
                        :dept :sum_nope)))
  {:error :malformed-tree :why :group-agg-row-scope :name "nope"
   :node {:node :group :keys [:dept]
          :aggs [{:expr :agg :agg :sum :arg {:expr :get :col :nope :alias nil}}]
          :input {:node :from :src @{:backend :rayforce :columns (tuple (tuple "id" (tuple 1 2 3 4))
                                                (tuple "dept" (tuple 1 1 2 nil))
                                                (tuple "pay" (tuple 1.5 2.5 3.5 4.5)))} :alias nil}}
   :backend :rayforce}
  "fence-agg|fence 2 raises the class before any engine call
(naming the group node and the column)")

# == served operators =====================================================
# s3-rf-from / dataset: implicit projection, source order, NULL -> nil
(assert-eq (ex (jq/from ds))
           @{:columns @[:id :dept :pay]
             :rows @[[1 1 1.5] [2 1 2.5] [3 2 3.5] [4 nil 4.5]]}
           "from|dataset (ordered pairs, NULL -> nil)")

# from: a borrowed module table handle
(do
  (def tbl (rf/table-from-columns @{:a @[1 2] :b @[3.5 4.5]}))
  (def res (ex (jq/from @{:backend :rayforce :handle tbl})))
  (assert-eq (rows-sorted res)
             (rows-sorted @{:rows @[[1 3.5] [2 4.5]]})
             "from|handle (borrowed, never closed by the backend)")
  (:close tbl))

# from: a catalog-named table is NOT bindable on rayforce
(assert-err (fn [] (ex (jq/from :emp)))
  {:error :malformed-tree :why :rayforce-unbindable-source
   :node {:node :from :src :emp :alias nil} :name :emp
   :backend :rayforce}
  "from|unbindable (catalog-named SQL table)")

# select
(assert-eq (ex (jq/select (jq/from ds) :id :pay))
           @{:columns @[:id :pay]
             :rows @[[1 1.5] [2 2.5] [3 3.5] [4 4.5]]}
           "select|base (source-named projection)")
(assert-err (fn [] (ex (jq/select (jq/from ds) (jq/add (jq/get :id) (jq/lit 1)))))
  {:error :extension-denied :operator :select :backend :rayforce
   :why :expression-projection}
  "select|expression projection denied (the per-backend lane)")

# where: two-valued nulls (documented divergence from SQL three-valued)
(assert-eq (ex (jq/where (jq/from ds) (jq/lt (jq/get :pay) (jq/lit 3))))
           @{:columns @[:id :dept :pay]
             :rows @[[1 1 1.5] [2 1 2.5]]}
           "where|base")
(def dsn @{:backend :rayforce
           :columns @[@["x" @[1.0 nil 3.0]]]})
(assert-eq (ex (jq/where (jq/from dsn) (jq/lt (jq/get :x) (jq/lit 3))))
           @{:columns @[:x] :rows @[[1] [nil]]}
           "where|null-two-valued (null compares as -inf, KEPT by lt -
the documented divergence from SQL's unknown-drops)")
# consecutive wheres merge (the and-composition identity)
(assert-eq (ex (jq/where (jq/where (jq/from ds) (jq/lt (jq/get :pay) (jq/lit 4)))
                         (jq/lt (jq/get :id) (jq/lit 3))))
           @{:columns @[:id :dept :pay] :rows @[[1 1 1.5] [2 1 2.5]]}
           "where|merge (consecutive wheres and-compose over the source)")
# where after a row-reducing op: materialise boundary, mask stays aligned
(assert-eq (ex (jq/where (jq/limit (jq/from ds) 3)
                         (jq/lt (jq/get :id) (jq/lit 3))))
           @{:columns @[:id :dept :pay] :rows @[[1 1 1.5] [2 1 2.5]]}
           "where|after-limit (mask alignment, materialised)")

# order + limit head/tail
(assert-eq (ex (jq/order (jq/limit (jq/from ds) 2 :tail) [:id :asc]))
           @{:columns @[:id :dept :pay] :rows @[[3 2 3.5] [4 nil 4.5]]}
           "limit|tail")
(assert-eq (ex (jq/limit (jq/order (jq/from ds) [:id :desc]) 2))
           @{:columns @[:id :dept :pay] :rows @[[4 nil 4.5] [3 2 3.5]]}
           "order|base + limit head (desc, engine-ordered)")
# order nulls: desc puts nulls first (the duckdb DESC NULLS FIRST
# convention; ASC nulls-last both engines)
(assert-eq (ex (jq/order (jq/from ds) [:dept :desc]))
           @{:columns @[:id :dept :pay]
             :rows @[[4 nil 4.5] [3 2 3.5] [1 1 1.5] [2 1 2.5]]}
           "order|nulls-first-on-desc (matches the duckdb convention)")
(assert-eq (ex (jq/order (jq/from ds) [:dept :asc]))
           @{:columns @[:id :dept :pay]
             :rows @[[1 1 1.5] [2 1 2.5] [3 2 3.5] [4 nil 4.5]]}
           "order|nulls-last-on-asc")

# distinct (full-row, over all output columns)
(assert-eq (rows-sorted (ex (jq/distinct (jq/select (jq/from ds) :dept))))
           (rows-sorted @{:rows @[[1] [2] [nil]]})
           "distinct|base+null (NULL distinct once)")
# distinct after a where: materialise boundary
(assert-eq (rows-sorted (ex (jq/distinct (jq/where (jq/from ds)
                                                  (jq/lt (jq/get :id) (jq/lit 3))))))
           (rows-sorted @{:rows @[[1 1 1.5] [2 1 2.5]]})
           "distinct|after-where (boundary materialisation)")

# group: the shared aggregate set, contract output names (agg_col)
(assert-eq (rows-sorted (ex (jq/select (jq/group (jq/from ds) [:dept]
                                                 (jq/sum (jq/get :pay)))
                                       :dept :sum_pay)))
           (rows-sorted @{:columns @[:dept :sum_pay]
                          :rows @[[1 4] [2 3.5] [nil 4.5]]})
           "group|base (sum per key, NULL a key value, agg_col name)")
(assert-eq (rows-sorted (ex (jq/select (jq/group (jq/from ds) [:dept]
                                                 (jq/count (jq/get :dept)))
                                       :dept :count_dept)))
           (rows-sorted @{:columns @[:dept :count_dept]
                          :rows @[[1 2] [2 1] [nil 1]]})
           "group|null-agg (count is the shared ROW-COUNT
aggregate - the nil-dept group counts its
row, matching duckdb's COUNT(*))")
# all shared aggs, per key (hand-computed; sample stddev/var - the
# single-row groups give nil, duckdb NULL - the documented NaN lane)
(assert-eq (ex (jq/order (jq/select (jq/group (jq/from ds) [:dept]
                                              (jq/min (jq/get :pay))
                                              (jq/max (jq/get :pay))
                                              (jq/avg (jq/get :pay))
                                              (jq/stddev (jq/get :pay))
                                              (jq/var (jq/get :pay))
                                              (jq/first (jq/get :pay))
                                              (jq/last (jq/get :pay)))
                                    :dept :min_pay :max_pay :avg_pay :stddev_pay
                                    :var_pay :first_pay :last_pay)
                         [:dept :asc]))
           @{:columns @[:dept :min_pay :max_pay :avg_pay :stddev_pay :var_pay
                :first_pay :last_pay]
             :rows @[[1 1.5 2.5 2 0.70710678118654757 0.5 1.5 2.5]
                     [2 3.5 3.5 3.5 nil nil 3.5 3.5]
                     [nil 4.5 4.5 4.5 nil nil 4.5 4.5]]}
           "group|all shared aggs (sample flavour, single-row nil)")
# no-keys group: the engine requires keys - a named gap, never a
# substitute (duckdb serves GROUP BY ALL)
(assert-err (fn [] (ex (jq/select (jq/group (jq/from ds) [] (jq/sum (jq/get :pay)))
                                  :sum_pay)))
  {:error :malformed-tree :why :rayforce-no-keys-group
   :node {:node :group :keys []
          :aggs [{:expr :agg :agg :sum :arg {:expr :get :col :pay :alias nil}}]
          :input {:node :from :src @{:backend :rayforce :columns (tuple (tuple "id" (tuple 1 2 3 4))
                                                (tuple "dept" (tuple 1 1 2 nil))
                                                (tuple "pay" (tuple 1.5 2.5 3.5 4.5)))} :alias nil}}
   :backend :rayforce}
  "group|no-keys raise (ray_group requires a key - the global-
aggregate shape is a named gap)")
# group after a where (boundary materialisation, prefix chain executes)
(assert-eq (rows-sorted (ex (jq/select (jq/group (jq/where (jq/from ds)
                                                          (jq/lt (jq/get :id) (jq/lit 4)))
                                                 [:dept] (jq/sum (jq/get :pay)))
                                       :dept :sum_pay)))
           (rows-sorted @{:rows @[[1 4] [2 3.5]]})
           "group|after-where (the prefix chain materialises first)")
# where after a group (boundary materialisation, contract names)
(assert-eq (ex (jq/where (jq/select (jq/group (jq/from ds) [:dept]
                                             (jq/sum (jq/get :pay)))
                                :dept :sum_pay)
                         (jq/lt (jq/get :sum_pay) (jq/lit 5))))
           @{:columns @[:dept :sum_pay] :rows @[[1 4] [2 3.5] [nil 4.5]]}
           "group|where-after-group (renamed agg columns resolvable;
every group sum is < 5 here - the lane is the resolution, the filter
engine-side)")

# STR lanes (parquet, terminal group - no re-ingest; unordered, compared
# as a multiset)
(do
  (def pq "test/fixtures/rayforce/str-agg.parquet")
  (def res (ex (jq/select (jq/group (jq/from-parquet pq) [:s]
                                    (jq/count (jq/get :t))
                                    (jq/first (jq/get :t))
                                    (jq/last (jq/get :t)))
                          :s :count_t :first_t :last_t)))
  (assert-eq (rows-sorted res)
             (rows-sorted @{:rows @[[nil 2 "ab" "ab"] ["aa" 2 "aa" "ab"]
                                    ["aaa" 1 "a" "a"] ["bb" 2 "aa" "bb"]]})
                           "group|str-key + type-agnostic aggs (first/last skip
NULLs - duckdb FIRST/LAST semantics; STR decode copies values,
empty text -> nil documented)")
  # a chain node AFTER a STR-bearing group hits the numeric-only
  # re-ingest boundary - named, never silent
  (def strb (catch-err
              (fn [] (ex (jq/where (jq/select (jq/group (jq/from-parquet pq) [:s]
                                                       (jq/count (jq/get :t)))
                                          :s :count_t)
                                    (jq/lt (jq/get :count_t) (jq/lit 2)))))))
  (assert-eq (get strb :why) :rayforce-str-boundary
             "group|str-boundary (a post-chain over a STR-bearing
group raises the named boundary - the re-ingest is numeric-only)"))

# join: inner/left/full (null keys MATCH - the documented divergence)
(def ds2 @{:backend :rayforce
           :columns @[@["dept" @[1 2]] @["floor" @[7 8]]]})
(assert-eq (ex (jq/order (jq/select (jq/join (jq/from ds) (jq/from ds2)
                                             [:dept] [:dept] :inner)
                                    (jq/get :id) (jq/get :floor))
                         [:id :asc]))
           @{:columns @[:id :floor] :rows @[[1 7] [2 7] [3 8]]}
           "join|base (collision sides renamed by copy, plain output)")
(def dsk @{:backend :rayforce
           :columns @[@["k" @[1.0 2.0 nil]] @["a" @[10.0 20.0 30.0]]]})
(def dsk2 @{:backend :rayforce
            :columns @[@["k" @[2.0 3.0 nil]] @["b" @[200.0 300.0 600.0]]]})
(assert-eq (rows-sorted (ex (jq/select (jq/join (jq/from dsk) (jq/from dsk2)
                                                [:k] [:k] :inner)
                                       (jq/get :a) (jq/get :b))))
           (rows-sorted @{:rows @[[20 200] [30 600]]})
           "join|null-key (null MATCHES null on rayforce - the
documented divergence; duckdb inner gives only the 2-row match, no
null-null row)")
(assert-eq (rows-sorted (ex (jq/select (jq/join (jq/from dsk) (jq/from dsk2)
                                                [:k] [:k] :left)
                                       (jq/get :a) (jq/get :b))))
           (rows-sorted @{:rows @[[10 nil] [20 200] [30 600]]})
           "join|left (the null-key pair FILLS - duckdb gives (30 nil))")
# self-join with aliases: renamed-copy sides, aliased refs resolve
(assert-eq (ex (jq/select (jq/join (jq/from ds :alias :e1) (jq/from ds :alias :e2)
                                  [:id] [:id] :inner)
                          (jq/get :id :e1) (jq/get :pay :e1) (jq/get :pay :e2)))
           @{:columns @[:id :pay :pay]
             :rows @[[1 1.5 1.5] [2 2.5 2.5] [3 3.5 3.5] [4 4.5 4.5]]}
           "join|self-alias (renamed-copy strategy, P14)")
# join-key scope fence
(assert-err (fn [] (ex (jq/select (jq/join (jq/from ds) (jq/from ds2)
                                            [:nope] [:dept] :inner)
                                   (jq/get :id))))
  {:error :malformed-tree :why :rayforce-join-key-scope :name "l.nope"
   :backend :rayforce
   :node {:node :join :type :inner
          :left {:node :from
                 :src @{:backend :rayforce
                        :columns (tuple (tuple "id" (tuple 1 2 3 4))
                                        (tuple "dept" (tuple 1 1 2 nil))
                                        (tuple "pay" (tuple 1.5 2.5 3.5 4.5)))}
                 :alias nil}
          :right {:node :from
                  :src @{:backend :rayforce
                         :columns (tuple (tuple "dept" (tuple 1 2))
                                         (tuple "floor" (tuple 7 8)))}
                  :alias nil}
          :lkeys [:nope] :rkeys [:dept]}}
  "join|key-scope fence (key resolves against its side)")
# where after a join (boundary materialisation; side-map survives)
(assert-eq (ex (jq/where (jq/select (jq/join (jq/from ds) (jq/from ds2)
                                             [:dept] [:dept] :inner)
                                    (jq/get :id) (jq/get :floor))
                         (jq/lt (jq/get :floor) (jq/lit 8))))
           @{:columns @[:id :floor] :rows @[[1 7] [2 7]]}
           "join|where-after-join (materialised, plain names resolve)")
# nested joins: a join over a join (the Q3 reporting chain shape). The
# engine's join emits the left side's columns plus the right side's
# uniquely-named ones, and never the right key under its own name; the
# segment's :out must be that set, or the next materialisation decodes a
# phantom column (the decode raises "expected array or tuple, got nil")
(def djoin-l @{:backend :rayforce
               :columns @[@["emp" @[1 2 3 4]] @["mgr" @[0 1 2 2]]]})
(def djoin-m @{:backend :rayforce
               :columns @[@["cust" @[1 2 3 4]] @["rep" @[3 3 4 4]]]})
(def djoin-r @{:backend :rayforce
               :columns @[@["inv" @[1 2 3 4]] @["cid" @[1 1 2 3]]
                          @["amt" @[10.0 20.0 30.0 40.0]]]})
(assert-eq (rows-sorted
             (ex (jq/select (jq/join (jq/join (jq/from djoin-l) (jq/from djoin-m)
                                              [:emp] [:rep] :inner)
                                     (jq/from djoin-r) [:cust] [:cid] :inner)
                            (jq/get :mgr) (jq/get :amt))))
           (rows-sorted @{:rows @[[2 10] [2 20] [2 30] [2 40]]})
           "join|nested (a join over a join reads the engine's real
 output, not a phantom right-key column)")

# expressions: the shared core + the floor-lane idiv/mod (P6).
# Expression projections are the per-backend lane (denied above), so
# the idiv/mod lanes run through where - the WHERE form is equivalent
(assert-eq (ex (jq/where (jq/from ds) (jq/eq (jq/idiv (jq/get :id) (jq/lit 2))
                                             (jq/lit 1))))
           @{:columns @[:id :dept :pay] :rows @[[2 1 2.5] [3 2 3.5]]}
           "idiv|floor lane (positive dividends agree with duckdb)")
(def dsm @{:backend :rayforce :columns @[@["a" @[7 -7]]]})
(assert-eq (ex (jq/where (jq/from dsm) (jq/eq (jq/idiv (jq/get :a) (jq/lit 2))
                                              (jq/lit -4))))
           @{:columns @[:a] :rows @[[-7]]}
           "idiv|floor divergence (idiv floors: -7//2 = -4, duckdb
truncates to -3 - the documented P6 per-backend divergence)")
(assert-eq (ex (jq/where (jq/from dsm) (jq/eq (jq/mod (jq/get :a) (jq/lit 2))
                                              (jq/lit 1))))
           @{:columns @[:a] :rows @[[7] [-7]]}
           "idiv|mod floors (-7%2 = +1 on rayforce; duckdb gives
-1, sign of dividend - the documented P6 divergence)")
(assert-eq (ex (jq/where (jq/from ds)
                         (jq/and2 (jq/gt (jq/get :id) (jq/lit 1))
                                   (jq/or2 (jq/eq (jq/get :dept) (jq/lit 2))
                                           (jq/isnull (jq/get :dept))))))
           @{:columns @[:id :dept :pay] :rows @[[3 2 3.5] [4 nil 4.5]]}
           "expr|core (and/or/gt/eq/isnull compose)")
(assert-eq (ex (jq/where (jq/from dsn)
                         (jq/eq (jq/if2 (jq/isnull (jq/get :x))
                                        (jq/lit -1)
                                        (jq/get :x))
                                (jq/lit -1))))
           @{:columns @[:x] :rows @[[nil]]}
           "expr|if + isnull (the null row maps to -1 through the
conditional; expression projections are denied, so the lane runs in a
predicate)")
# nil/string literals raise the named boundaries
# nil/string literals raise the named boundaries (struct grammar:
# compare the :why fact)
(assert-eq (get (catch-err (fn [] (ex (jq/where (jq/from ds)
                                               (jq/lt (jq/get :id) (jq/lit nil))))))
               :why)
           :rayforce-nil-literal
           "expr|nil-literal boundary (compose through isnull instead)")
(assert-eq (get (catch-err (fn [] (ex (jq/where (jq/from ds)
                                               (jq/eq (jq/get :dept) (jq/lit "a"))))))
               :why)
           :rayforce-string-literal
           "expr|string-literal boundary (the string-expression gap)")

# == the denial matrix rows (operator + backend named, at expansion) ====
(assert-err (fn [] (ex (jq/join (jq/from ds) (jq/from ds2) [:dept] [:dept] :anti)))
  {:error :extension-denied :operator :join-anti :backend :rayforce}
  "deny|anti (jtype-3 silently wrong; ray_antijoin unbound)")
(assert-err (fn [] (ex (jq/join (jq/from dsk) (jq/from dsk2) [:k] [:k] :asof)))
  {:error :extension-denied :operator :asof :backend :rayforce}
  "deny|asof (ray_asof_join unbound)")
(assert-err (fn [] (ex (jq/select (jq/group (jq/from ds) [:dept]
                                            (jq/count-distinct (jq/get :id)))
                                  :dept :count-distinct_id)))
  {:error :extension-denied :operator :count-distinct :backend :rayforce}
  "deny|count-distinct (the distinct+count composition is the
documented rayforce-side recipe)")
(assert-err (fn [] (ex (jq/select (jq/group (jq/from ds) [] (jq/median (jq/get :pay)))
                                  :median_pay)))
  {:error :extension-denied :operator :median :backend :rayforce}
  "deny|median (absent from the module agg surface)")
(assert-err (fn [] (ex (jq/append (jq/select (jq/from ds) :id)
                                 (jq/select (jq/from ds) :id))))
  {:error :extension-denied :operator :append :backend :rayforce}
  "deny|append (ray_lazy_append unbound; duckdb-declared extension)")
(assert-err (fn [] (ex (jq/write-parquet (jq/from ds) "/tmp/x.parquet")))
  {:error :extension-denied :operator :write-parquet :backend :rayforce}
  "deny|write-parquet (no parquet write surface)")
(assert-err (fn [] (ex (jq/window (jq/from ds))))
  {:error :extension-denied :operator :window :backend :rayforce}
  "deny|window (ray_window_op unbound)")
(assert-err (fn [] (ex (jq/where (jq/from ds) (jq/in (jq/get :id) [1 2]))))
  {:error :extension-denied :operator :expr-in :backend :rayforce}
  "deny|in (ray_in unbound)")
(assert-err (fn [] (ex (jq/where (jq/from ds)
                                  (jq/and2 (jq/escape :rayforce "x") (jq/lit true)))))
  {:error :extension-denied :operator :escape :backend :rayforce}
  "deny|escape (graph-scoped splice needs a janet-rayforce slice)")

# == the engine form + execute ==============================================
(def render-q (jq/select (jq/from ds) :id))
(def form (jq/render render-q :backend :rayforce))
(assert-eq (get form :form) :dag-per-execution
           "wrapper|render is inert data (the DAG builds per execution)")
# re-executing the same query: fresh graphs, same answer (the fresh-graph rule)
(assert-eq (jq/execute render-q :backend :rayforce)
           (jq/execute render-q :backend :rayforce)
           "wrapper|re-execute a query (fresh graphs per call)")

# == the leak tier: net 0 per translate-execute-decode cycle ==============
(do
  (def cycles 20)
  (def leak-q (jq/select (jq/group (jq/where (jq/from ds)
                                             (jq/lt (jq/get :id) (jq/lit 4)))
                                    [:dept] (jq/sum (jq/get :pay)))
                         :dept :sum_pay))
  (def [net allocs frees leak-result]
    (rf/-trace-net
      (fn []
        (var l nil)
        (for i 0 cycles
          (set l (jq/execute leak-q :backend :rayforce)))
        l)))
  (def net* (if (number? net) net (int/to-number net)))
  (assert-eq net* 0
             (string/format "leak|cycle net 0 (%d cycles, %d allocs, %d frees)"
                            cycles allocs frees))
  (assert-eq (type leak-result) :table
             "leak|every cycle returned a wrapper"))

# == dual-backend equivalence, the shared surface (first pass; slice 4
# formalises - same tree shape, both backends, value-compared per
# contract 6; the from SOURCE differs by necessity - a duckdb SQL table
# vs a rayforce in-janet dataset, identical row arrays)
(do
  (def rows @[[1 1 1.5] [2 1 2.5] [3 2 3.5] [4 nil 4.5]])
  (def c (jqd/conn))
  (duckdb/exec c "DROP TABLE IF EXISTS eq_emp")
  (duckdb/exec c "CREATE TABLE eq_emp (id INTEGER, dept INTEGER, pay DOUBLE)")
  (each r rows
    (duckdb/exec c "INSERT INTO eq_emp VALUES (?, ?, ?)"
                 [(r 0) (r 1) (r 2)]))
  (def dse @{:backend :rayforce
            :columns @[@["id" @[1 2 3 4]]
                       @["dept" @[1 1 2 nil]]
                       @["pay" @[1.5 2.5 3.5 4.5]]]})
  # the same tree shape per backend: the from source is the only
  # backend-specific part (the binding set)
  (duckdb/exec c "DROP TABLE IF EXISTS eq_dept")
  (duckdb/exec c "CREATE TABLE eq_dept (dept INTEGER, floor INTEGER)")
  (each r @[[1 7] [2 8]]
    (duckdb/exec c "INSERT INTO eq_dept VALUES (?, ?)" [(r 0) (r 1)]))
  (defn equiv [build msg &opt cmp]
    (def d (jq/execute (build :duckdb) :backend :duckdb))
    (def r (jq/execute (build :rayforce) :backend :rayforce))
    (if cmp
      (unless (cmp d r) (errorf "FAIL %s: %q != %q" msg d r))
      (assert-eq (rows-sorted r) (rows-sorted d) msg)))
  (defn from-of [b] (if (= b :duckdb) (jq/from :eq_emp) (jq/from dse)))
  (equiv (fn [b] (jq/select (from-of b) :id :pay))
         "equiv|select (source-named, unordered)")
  (equiv (fn [b] (jq/order (jq/select (from-of b) :id) [:id :desc]))
         "equiv|order+select (ordered)")
  (equiv (fn [b] (jq/limit (jq/order (from-of b) [:id :asc]) 2))
         "equiv|limit head over order")
  (equiv (fn [b] (jq/limit (jq/order (from-of b) [:id :asc]) 2 :tail))
         "equiv|limit tail over order")
  (equiv (fn [b] (jq/distinct (jq/select (from-of b) :dept)))
         "equiv|distinct incl NULL")
  (equiv (fn [b] (jq/order (jq/select (jq/group (from-of b) [:dept]
                                               (jq/sum (jq/get :pay)))
                              :dept :sum_pay)
                    [:dept :asc]))
         "equiv|group sum (NULL a key value, agg_col names match)")
  (equiv (fn [b] (jq/order (jq/select (jq/group (from-of b) [:dept]
                                               (jq/count (jq/get :id)))
                              :dept :count_id)
                    [:dept :asc]))
         "equiv|group count")
  (equiv (fn [b] (jq/order (jq/select (jq/group (from-of b) [:dept]
                                               (jq/min (jq/get :pay))
                                               (jq/max (jq/get :pay))
                                               (jq/avg (jq/get :pay))
                                               (jq/stddev (jq/get :pay))
                                               (jq/var (jq/get :pay))
                                               (jq/first (jq/get :pay))
                                               (jq/last (jq/get :pay)))
                              :dept :min_pay :max_pay :avg_pay :stddev_pay
                              :var_pay :first_pay :last_pay)
                    [:dept :asc]))
         "equiv|group all shared aggs (sample stddev/var; single-row
groups NULL/nil - the documented NaN lane, identical here)"
         (fn [d r]
           (and (deep= (get d :columns) (get r :columns))
                (all (fn [i] (rows-close ((get d :rows) i)
                                          ((get r :rows) i) 1e-12))
                     (range (length (get d :rows)))))))
  (equiv (fn [b] (jq/where (from-of b) (jq/lt (jq/get :pay) (jq/lit 3))))
         "equiv-where|null-free where lane (both extensions, null-free
data - the same rows)")
  (equiv (fn [b] (jq/order (jq/select (jq/join (from-of b)
                                               (if (= b :duckdb)
                                                 (jq/from :eq_dept)
                                                 (jq/from ds2))
                                               [:dept] [:dept] :inner)
                                   (jq/get :id) (jq/get :floor))
                    [:id :asc]))
         "equiv-join|null-free join lane (inner, keys without nulls)")
  # documented-divergence lanes (asserted as divergences, not equivalence)
  (def d (jq/execute (jq/where (from-of :duckdb) (jq/lt (jq/get :dept) (jq/lit 2)))
                     :backend :duckdb))
  (def r (jq/execute (jq/where (from-of :rayforce) (jq/lt (jq/get :dept) (jq/lit 2)))
                     :backend :rayforce))
  (assert (not (deep= (rows-sorted d) (rows-sorted r)))
          "diverge-where|duckdb drops the nil-dept row (unknown),
rayforce keeps it (null as -inf) - the documented two-valued divergence")
  # NaN payload (rayforce nil-unified, duckdb NaN-distinct)
  (duckdb/exec c "DROP TABLE IF EXISTS eq_nan")
  (duckdb/exec c "CREATE TABLE eq_nan (x DOUBLE)")
  (duckdb/exec c "INSERT INTO eq_nan VALUES (1.0), (CAST('nan' AS DOUBLE)), (2.0)")
  (def rd (jq/execute (jq/from :eq_nan) :backend :duckdb))
  (def rr (jq/execute (jq/from @{:backend :rayforce
                                :columns @[@["x" @[1.0 math/nan 2.0]]]})
                      :backend :rayforce))
  # NaN != NaN under = - compare positionally with nan? (the NaN lane
  # IS the divergence: duckdb row 2 NaN-distinct, rayforce nil)
  (def drows (get rd :rows))
  (assert (and (= 3 (length drows))
               (= 1 ((drows 0) 0))
               (nan? ((drows 1) 0))
               (= 2 ((drows 2) 0)))
          "diverge-nan|duckdb keeps NaN-distinct (row 2 is NaN)")
  (assert-eq (get rr :rows) @[[1] [nil] [2]]
             "diverge-nan|rayforce unifies to nil"))

# == the count-distinct expansion surface ====================================
# The matrix denies the count-distinct NODE on rayforce; the matrix-declared
# :expansion strategy rewrites it into the shared two-graph composition
# (project keys+col -> distinct full rows -> grouped count). On rayforce
# that composition exercises the intermediate-table ownership path: the
# distinct RESULT re-ingests into a fresh backend-owned SEGMENT for the
# following group, closed exactly once on the path. Lanes: the engine
# equivalence, a crash-class child (a premature close of the
# intermediate is a use-after-free: the child dies, the parent
# survives), a leak-class trace (an intermediate never closed shows net
# non-zero), idempotence across executions (fresh graphs), and the
# nested-group shape (a count-distinct group over a grouped input).
(do
  (def shared-matrix
    {:from :shared :group :shared :select :shared :order :shared
     :limit :shared :distinct :shared :from-parquet :shared})
  (jq/register-backend!
    @{:name :f-cd-s5
      :renderer (fn [tree] @{:sql "FAKE" :tree tree :params @[]})
      :execute (fn [form] @{:rows @[] :columns @[]})
      :catalog-spec @{}
      :matrix (merge shared-matrix {:count-distinct :expansion})})
  (def pq "test/fixtures/chinook/chinook.parquet")
  (def cd-tree (jq/group (jq/from-parquet pq) [:customerid]
                         (jq/count-distinct (jq/get :invoicedate))))
  (def cd-exp (get (jq/render cd-tree :backend :f-cd-s5) :tree))
  (assert-eq (get cd-exp :node) :group
             "s5-cd-engine|rewrite lands the two-graph composition")
  # engine lane: the expanded tree runs the rayforce ownership path and
  # matches duckdb's NATIVE count-distinct over the same bytes
  (def r-exp (jq/execute cd-exp :backend :rayforce))
  (def r-nat (jq/execute cd-tree :backend :duckdb))
  (assert (and (= 60 (length (get r-exp :rows)))
               (deep= (rows-sorted r-exp) (rows-sorted r-nat)))
          "s5-cd-engine|expansion on rayforce == native on duckdb (60x14)")
  # idempotence: repeated executions of the expanded query are identical
  (def r-exp2 (jq/execute cd-exp :backend :rayforce))
  (assert (deep= (get r-exp :rows) (get r-exp2 :rows))
          "s5-cd-idem|re-execution of an expanded query is idempotent")
  # leak class: net 0 per cycle under ray_mem_trace - an intermediate
  # table never closed would surface as net non-zero
  (def cycles 20)
  (def [net allocs frees leak-result]
    (rf/-trace-net
      (fn []
        (var l nil)
        (for i 0 cycles
          (set l (jq/execute cd-exp :backend :rayforce)))
        l)))
  (def net* (if (number? net) net (int/to-number net)))
  (assert-eq net* 0
              (string/format
                "s5-cd-leak|cycle net 0 (%d cycles, %d allocs, %d frees)"
                cycles allocs frees))
  (assert-eq (type leak-result) :table
              "s5-cd-leak|every cycle returned a wrapper")
  # crash class: the expanded execution runs in a child process; a
  # use-after-free or double close of the intermediate kills the child
  # (exit 139), a clean run exits 0
  (defn subprobe [code]
    (def script "/tmp/jq-s5-sub.janet")
    (def out "/tmp/jq-s5-sub.txt")
    (spit script code)
    (def rc (os/execute ["/bin/sh" "-c"
                         (string "JANET_PATH="
                                 (or (get (os/environ) "JANET_PATH")
                                     "test/lib")
                                 " janet " script " > " out " 2>&1")]))
    (def msg (string/trim (string (slurp out))))
    (when (os/stat out) (os/rm out))
    [rc msg])
  (def [rc msg] (subprobe (string
    "(import jennystats/query :prefix \"jq/\")\n"
    "(import jennystats/query-rayforce)\n"
    "(import jennystats/query-duckdb)\n"
    "(jq/register-backend!\n"
    " @{:name :f-cd-s5\n"
    "   :renderer (fn [tree] @{:sql \"FAKE\" :tree tree :params @[]})\n"
    "   :execute (fn [form] @{:rows @[] :columns @[]})\n"
    "   :catalog-spec @{}\n"
    "   :matrix {:from :shared :group :shared :select :shared :order :shared\n"
    "            :limit :shared :distinct :shared :from-parquet :shared\n"
    "            :count-distinct :expansion}})\n"
    "(def cd-tree (jq/group (jq/from-parquet\n"
    "  \"test/fixtures/chinook/chinook.parquet\") [:customerid]\n"
    "  (jq/count-distinct (jq/get :invoicedate))))\n"
    "(def cd-exp (get (jq/render cd-tree :backend :f-cd-s5) :tree))\n"
    "(def r (jq/execute cd-exp :backend :rayforce))\n"
    "(def r2 (jq/execute cd-exp :backend :rayforce))\n"
    "(unless (and (= 60 (length (get r :rows)))\n"
    "              (deep= (get r :rows) (get r2 :rows)))\n"
    "  (error \"child mismatch\"))\n"
    "(print \"child ok: 60 rows, idempotent\")")))
  (assert (and (= rc 0) (string/find "child ok" msg))
          (string "s5-cd-crash|child survives the expanded path: rc "
                  rc ": " msg))
  # nested-group: a count-distinct group whose input is itself a group
  # (the expansion runs over an already-grouped chain; both engines agree)
  (def nested-in (jq/group (jq/from-parquet pq) [:customerid]
                           (jq/sum (jq/get :total))))
  (def nested (jq/group nested-in [:customerid]
                        (jq/count-distinct (jq/get :sum_total))))
  (def nx (get (jq/render nested :backend :f-cd-s5) :tree))
  (def r-nested (jq/execute nx :backend :rayforce))
  (def r-nd (jq/execute nested :backend :duckdb))
  (assert (and (= 60 (length (get r-nested :rows)))
               (deep= (rows-sorted r-nested) (rows-sorted r-nd)))
          "s5-cd-nested|expansion under a nested group, both engines agree"))

#==------------------------------------------------------------------------==#
# Literal NaN normalisation on the rayforce render
# ---------------------------------------------------------------------------
# The rayforce f64 lane has ONE null encoding (any NaN IS a null). A literal NaN in a query was translated straight to a const-f64
# node, so the engine folded it to null silently - the query layer never
# said so. The renderer now normalises a literal NaN to an explicit NULL
# in the carrier tree it hands back, which is the observable render form
# for this backend (the DAG is built per execution).
#==------------------------------------------------------------------------==#

(def nan-ds @{:backend :rayforce :columns @[@["a" @[1.0 2.0]]]})
(defn nan-lit-in-pred [v]
  (jq/where (jq/from nan-ds)
            {:expr :call :op :lt
             :args [{:expr :get :col :a :alias nil} {:expr :lit :value v}]}))
(defn nan-lit-in-value [v]
  (jq/group (jq/from nan-ds) [:a] (jq/min (jq/lit v))))

# 1. the RENDER carries NULL, not NaN, for a literal in a predicate. The
#    whole tree is walked, not one known path: the normalisation is a
#    property of the form, so no NaN may survive anywhere in it.
(defn nan-anywhere? [x]
  (cond (nan? x) true
        (or (table? x) (struct? x)) (all (fn [k] (nan-anywhere? (get x k)))
                                         (keys x))
        (or (tuple? x) (array? x) (buffer? x))
        (all (fn [i] (nan-anywhere? (x i))) (range (length x)))
        false))
(def nan-form (jq/render (nan-lit-in-pred math/nan) :backend :rayforce))
(assert (not (nan-anywhere? (get nan-form :tree)))
        "s6-cr3b|render never hands NaN to the engine (pred lane)")
(def nan-render-lit (let [lit (get (get (get (get nan-form :tree) :pred) :args)
                                 1)]
                      lit))
(assert (= :lit (get nan-render-lit :expr))
        "s6-cr3b|render keeps the literal node (only its value is normalised)")
# janet dictionaries drop nil-valued entries, so a normalised literal IS
# the nil-literal shape - the same node a caller writes for nil
(def nan-render-val (if (nil? nan-render-lit) nil (get nan-render-lit :value)))
(assert (not (truthy? nan-render-val))
        "s6-cr3b|the normalised literal carries no value")
(assert (deep= nan-render-lit {:expr :lit})
        "nan|render normalises a pred literal NaN to NULL")
# ... an aggregate argument is a column REFERENCE:
# a literal in that slot is the malformed class, so the NaN-in-agg-value
# lane these cells used to walk is UNREACHABLE BY CONSTRUCTION. That is the
# fix, not a regression - the old cells were exercised through the
# `count_0` phantom. What remains testable is the rule itself: the render
# refuses the malformed tree instead of normalising a value into it.
(defn nan-agg-refused? []
  (try (do (jq/render (nan-lit-in-value math/nan) :backend :rayforce) false)
       ([e] (= :malformed-tree (get e :error)))))
(assert (nan-agg-refused?)
        "nan|a literal in the aggregate slot refuses")
# ... the control: a non-NaN literal keeps node, keys AND value
(def num-render (get (jq/render (nan-lit-in-pred 1.5) :backend :rayforce)
                     :tree))
(def num-render-lit (get (get (get num-render :pred) :args) 1))
(assert (= (get num-render-lit :expr) (get nan-render-lit :expr))
        "s6-cr3b|control: the control tree shape is the same")
(assert (= (get num-render-lit :value) 1.5)
        "s6-cr3b|control: a finite literal is unchanged")
# ... the caller's tree is not mutated by the render (the freeze rule)
(def nan-src-tree (nan-lit-in-pred math/nan))
(def nan-src-lit (get (get (nan-src-tree :pred) :args) 1))
(jq/render nan-src-tree :backend :rayforce)
(assert (nan? (get nan-src-lit :value))
        "s6-cr3b|render does not mutate the caller's tree")
# 2. the read side: the normalised NULL stays a LITERAL, so the shared
#    nil-literal boundary raises before any engine call - the query layer
#    states at execution what the render already showed.
(def nan-exec-err (catch-err (fn [] (jq/execute (nan-lit-in-pred math/nan)
                                                :backend :rayforce))))
(assert (= (get nan-exec-err :why) :rayforce-nil-literal)
        "s6-cr3b|the render's NULL is a nil literal the engine fence names")
(assert (= (get nan-exec-err :backend) :rayforce)
        "s6-cr3b|the boundary names the backend")
(assert (deep= (get nan-exec-err :node) {:expr :lit})
        "s6-cr3b|the boundary names the normalised literal node")
# ... the control still executes: a finite literal is an ordinary const
(def nan-control-rows
  (get (jq/execute (nan-lit-in-pred 1.5) :backend :rayforce) :rows))
(assert (= (length nan-control-rows) 1)
        "nan|control: a finite predicate literal still constrains")

#==------------------------------------------------------------------------==#
# The render walk keeps buffer BYTES. Rebuilding
# a buffer with `(buffer ;out)`, which janet STRINGIFIES: @"\x01\x02\xC8\xFF"
# became @"12200255" (8 ASCII bytes) through a real render.
#==------------------------------------------------------------------------==#
(def r3R-high-bytes @"\x01\x02\xC8\xFF")
(def r3R-buf-tree {:node :from :src nan-ds :alias nil :note r3R-high-bytes})
(def r3R-buf-rendered (get (get (jq/render r3R-buf-tree :backend :rayforce) :tree)
                           :note))
(assert (= true (buffer? r3R-buf-rendered))
        "buffer|stays a buffer through the render")
(assert (= (length r3R-buf-rendered) (length r3R-high-bytes))
        "buffer|length preserved (no stringification)")
(assert (not (some (fn [i] (not= (get r3R-buf-rendered i) (get r3R-high-bytes i)))
                   (range (length r3R-high-bytes))))
        "buffer|bytes identical to the caller's")
# the NaN rule still applies INSIDE a buffer-bearing tree (the walk is not
# side-stepped by the buffer branch)
(def r3R-buf-nan (get (jq/render {:node :from :src nan-ds :alias nil
                                  :note @"\xFF\x00"
                                  :spec {:v math/nan :b @"\x10\x20"}}
                                 :backend :rayforce) :tree))
(assert (not (nan-anywhere? r3R-buf-nan))
        "buffer|NaN still normalised beside a buffer")
(def r3R-nested-buf (get (get r3R-buf-nan :spec) :b))
(assert (= true (and (buffer? r3R-nested-buf)
                     (= (get r3R-nested-buf 0) 16) (= (get r3R-nested-buf 1) 32)))
        "buffer|nested buffer spec bytes preserved")
(print "RESULT: pass")
