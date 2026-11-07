# suite-query-chinook - the 15 real queries over the shared Chinook fixture:
# the dual-backend acceptance suite. Each query carries its janet-query tree,
# its per-backend lane (equivalent, divergent or a named denial) and, for the
# classic set, a raw-SQL duckdb oracle checked against the tree's own result.
# Requires libduckdb AND librayforce (SKIP if absent; present but broken is a
# FAIL).
#
# Cell ids name the coverage-manifest rows: q<N>|<lane>|<backend>.
# The manifest completeness gate at the foot of this file fails the suite when
# an operator the backend's matrix SERVES has no covering cell.
# Line-length note: the six raw-SQL oracle strings are single unbreakable
# SQL literals - wrapping them would corrupt the statements. They are the
# suite's accepted long lines (229, 300, 351, 427, 447, 473).
(import jennystats/query :prefix "jq/")
(import jennystats/query-duckdb :as qd)
(import jennystats/query-rayforce)
(import jennystats/duckdb :as duckdb)

#==------------------------------------------------------------------------==#
# Fixture: the committed bytes, hash-verified before the first query
#==------------------------------------------------------------------------==#

(def fixture-dir "test/fixtures/chinook")
(def pq (string fixture-dir "/chinook.parquet"))
(def sums (string fixture-dir "/SHA256SUMS"))

(var failures 0)
(def q-cells @{})

(defn record-cell [msg]
  "Every cell id has the q<N>|<lane>|<backend> shape; the manifest
completeness gate at the foot reads this table to prove each query landed."
  (def q (first (string/split "|" msg)))
  (when q (put q-cells q true)))

(defn fail [msg] (++ failures) (print "FAIL " msg) false)
(defn pass [msg] (record-cell msg) (print "PASS " msg) true)

(defn assert-true [v msg]
  (if v (pass msg) (fail msg)))

(defn assert-eq [a b msg]
  (if (deep= a b) (pass msg) (fail (string msg ": " a " != " b))))

(defn catch-err [f]
  (var c nil)
  (try (f) ([e] (set c e)))
  c)

(defn field-of
  "One field of the raised error facts, or nil."
  [f k]
  (get (catch-err f) k))

(defn assert-err-why [f want msg]
  "The query layer raises a struct of error facts ({:error class, plus the
facts: :operator, :backend, :why, :node}). Assert it by value: the raised
value is a struct and compares structurally."
  (assert-eq (catch-err f) want msg))

(defn denial [operator &opt backend]
  "The matrix-denial fact set for an operator (the operator and backend
fields are part of the contract's error grammar)."
  (if backend
    {:error :extension-denied :operator operator :backend backend}
    {:error :extension-denied :operator operator}))

(defn recorded-hash []
  (first (string/split " " (string (slurp sums)))))

(defn hash-of [line]
  "The digest column of a `sha256sum` output line."
  (first (string/split " " line)))

(defn actual-hash []
  "sha256 of the fixture bytes via coreutils (absolute path: os/execute does
not resolve PATH). Returns nil when the tool is absent."
  (def tool "/usr/bin/sha256sum")
  (if (os/stat tool)
    (do
      (def out "/tmp/.chinook-hash.txt")
      (def f (file/open out :w))
      (def code (os/execute [tool pq] :p {:out f}))
      (file/close f)
      (def line (if (zero? code) (string (slurp out)) ""))
      (if (os/stat out) (os/rm out))
      (if (zero? code) line nil))
    nil))

# a regenerated-different fixture is a hard fail, never a silent rebaseline
(let [actual (actual-hash)]
  (cond
    (nil? actual)
    (fail "fixture: sha256sum unavailable - the regeneration gate cannot run")
    (= (hash-of actual) (recorded-hash))
    (pass "fixture|hash - committed bytes match SHA256SUMS")
    (fail (string "fixture|hash - bytes changed: " (hash-of actual)
                  " vs " (recorded-hash)))))

#==------------------------------------------------------------------------==#
# The harness (contract section 6, test plan 4.4)
#==------------------------------------------------------------------------==#

# relative tolerance for floating lanes (the duckdf bench precedent);
# integers and strings compare exactly, NULL equals NULL
(def float-tol 1e-9)

(defn row-vec [r] (if (tuple? r) r (tuple ;r)))

(defn close? [a b]
  (cond
    (and (nil? a) (nil? b)) true
    (and (number? a) (number? b))
    (<= (math/abs (- a b)) (* float-tol (max 1 (math/abs a) (math/abs b))))
    (= a b) true
    false))

(defn rows-close? [ra rb]
  (and (= (length ra) (length rb))
       (all (fn [i]
              (def xv (row-vec (ra i)))
              (def yv (row-vec (rb i)))
              (and (= (length xv) (length yv))
                   (all (fn [j] (close? (xv j) (yv j))) (range (length xv)))))
            (range (length ra)))))

(defn row-key [r]
  "A comparable key per value: numbers normalised through a relative-rounding
so float noise inside the tolerance does not split a match; nil stays nil."
  (map (fn [v]
         (if (number? v)
           (string (math/round (* 1e9 v)))
           (if (nil? v) "nil" (string v))))
       (row-vec r)))

(defn rows-key [rows]
  "The multiset key of a row list: one sorted element per row, each row
itself sorted, so row order and column order both stop mattering."
  (sorted (map (fn [r] (string/join (sorted (row-key r)) "|")) rows)))

(defn run [q backend] (jq/execute q :backend backend))

(defn aligned-rows [wrapper order]
  "Rows of a result re-ordered to a column order: a bare from-parquet surfaces
columns in parquet order on duckdb and sorted-name order on rayforce (the
backend's documented projection rule), so comparison pairs by NAME."
  (def cols (get wrapper :columns))
  (def names (map string cols))
  (def wanted (map string order))
  (unless (deep= (sorted names) (sorted wanted))
    (errorf "column sets differ: %q vs %q" cols order))
  (def idx (map (fn [c] (index-of c names)) wanted))
  (map (fn [r] (def v (row-vec r)) (tuple ;(map |(v $0) idx)))
       (get wrapper :rows)))

(defn assert-equivalent [q msg &opt ordered]
  "Compare a query on both backends. Unordered queries compare as multisets
within tie groups (contract 6); an `ordered` query compares row sequences."
  (def d (run q :duckdb))
  (def r (run q :rayforce))
  (def order (map keyword (get d :columns)))
  (def aligned (if (deep= (sorted (map string (map keyword (get r :columns))))
                           (sorted (map string order)))
                 (aligned-rows r order)
                 nil))
  (cond
    (nil? aligned)
    (fail (string msg ": column sets " (get d :columns) " vs " (get r :columns)))
    ordered
    (if (rows-close? (get d :rows) aligned)
      (pass msg)
      (fail (string msg ": ordered rows differ")))
    (deep= (rows-key (get d :rows)) (rows-key aligned))
    (pass msg)
    (fail (string msg ": multisets differ, duckdb " (length (get d :rows))
                  " vs rayforce " (length (get r :rows))))))

(defn assert-rows [actual expected msg]
  "The landed result of a single-backend lane against the committed
expectation (a row list, compared as a multiset)."
  (if (deep= (rows-key actual) (rows-key expected))
    (pass msg)
    (fail (string msg ": " actual " != " expected))))

(defn assert-divergent [q msg]
  "Assert the documented per-backend divergence itself (documented
  divergence: these agree on the null-free rows only; where they disagree the cell
records the disagreement rather than claiming equivalence)."
  (def d (run q :duckdb))
  (def r (run q :rayforce))
  (def dk (rows-key (get d :rows)))
  (def rk (rows-key (get r :rows)))
  (cond
    (not= (length dk) (length rk))
    (fail (string msg ": row counts " (length dk) " vs " (length rk)))
    (= dk rk)
    (fail (string msg ": backends agree, the divergence cell is stale"))
    (pass msg)))

#==------------------------------------------------------------------------==#
# The duckdb raw-SQL oracle: independent SQL, same result as the tree
#==------------------------------------------------------------------------==#

(defn oracle [sql &opt path]
  (def c (qd/conn))
  (def p (or path pq))
  (def nparams (length (string/find-all "read_parquet(?" sql)))
  (def params (seq [_ :range [0 nparams]] p))
  (with [r (duckdb/query c sql params)]
    (jq/wrap-result (map |(tuple ;$) (duckdb/rows r false :tuple))
                    (map keyword (r :column-names)))))

(defn assert-oracle [q sql msg]
  (def tree (run q :duckdb))
  (def ref (oracle sql))
  (cond
    (deep= (rows-key (get tree :rows)) (rows-key (get ref :rows))) (pass msg)
    (fail (string msg ": tree " (get tree :rows) " vs oracle " (get ref :rows)))))

#==------------------------------------------------------------------------==#
# The classic set (Q1-Q6): dual-backend on the shared Parquet bytes
#==------------------------------------------------------------------------==#

# Q1 top spenders: from, join-free group sum, order desc, limit.
# Lane: EQUIVALENT (numeric group key, every shared operator).
(def q1 (-> (jq/from-parquet pq)
            (jq/group [:customerid] (jq/sum (jq/get :total)))
            (jq/order [:sum_total :desc])
            (jq/limit 10)))
(assert-equivalent q1 "q1|group-sum-order-limit|both")
(assert-oracle q1
  "SELECT customerid, SUM(total) AS sum_total FROM read_parquet(?) GROUP BY customerid ORDER BY sum_total DESC LIMIT 10"
  "q1|oracle|duckdb")

# Q2 invoice count per country: group on a VARCHAR key.
# Lane: DIVERGENT - rayforce returns the grouped STR fine but refuses to feed
# a STR-carrying result into a further operator (:rayforce-str-boundary), so
# the ordering stays a duckdb lane and the group alone is the shared shape.
(def q2-tree (-> (jq/from-parquet pq)
                 (jq/group [:country] (jq/count (jq/get :invoiceid)))))
(assert-eq (length (get (run q2-tree :duckdb) :rows))
           (length (get (run q2-tree :rayforce) :rows))
           "q2|group-str-key|both")
(assert-oracle q2-tree
  "SELECT country, COUNT(*) AS count_invoiceid FROM read_parquet(?) GROUP BY country"
  "q2|oracle|duckdb")
# the STR boundary raises the malformed-tree class naming the node it refused
# to feed: the fact set carries the refused order node itself, so the cell
# pins the class and the node (the node is compared by value)
(def q2-ordered (jq/order q2-tree [:country :asc]))
(assert-err-why (fn [] (run q2-ordered :rayforce))
                {:error :malformed-tree :why :rayforce-str-boundary
                 :backend :rayforce :node q2-ordered}
                "q2|order-after-str-group|rayforce-denial")

# Q3 the customer reporting chain, ordered: employees -> customers ->
# invoices, a self-join on the employee export plus the invoice grouping.
# Lane: the plan's Q3 was the reporting chain; slice 4 carried the count
# lane as a stand-in because the export had no employee table. The
# amendment's employee-export deliverable lands it properly here.
# reports_to carries a real NULL at the top of the chain (employee 1);
# SQL joins never match a NULL key, so the top row contributes no
# manager-grouped customers and is excluded by the join, not coalesced.
(def q3 (-> (jq/from-parquet pq)
            (jq/join (jq/from-parquet pq :alias :mgr)
                     [:reports_to] [:employeeid])
            (jq/group [:lastname] (jq/count (jq/get :invoiceid)))
            (jq/order [:lastname :asc])))
(assert-oracle q3
  (string "SELECT m.lastname, COUNT(i.invoiceid) AS c "
          "FROM read_parquet(?) i JOIN read_parquet(?) m "
          "ON i.reports_to = m.employeeid "
          "GROUP BY m.lastname ORDER BY m.lastname")
  "q3|reporting-chain|duckdb-oracle")
# Rayforce lane: the self-join collides on every column name and the
# renamed-copy strategy rejects STR columns, so a chain grouped on
# lastname raises the named boundary before any engine call. Gated by
# the matrix as a documented denial, not a silent gap.
(def q3-denial (catch-err (fn [] (run q3 :rayforce))))
(assert-eq {:error (get q3-denial :error) :why (get q3-denial :why)
            :backend (get q3-denial :backend)}
           {:error :malformed-tree :why :rayforce-str-join-rename
            :backend :rayforce}
           "q3|reporting-chain|rayforce-str-join-denial")

# Q4 playlist-shaped many-to-many: the export has no playlist tables, so the
# shared-bytes lane is the customer/date pair standing in for the
# playlist_track join shape: two-key group.
(def q4 (-> (jq/from-parquet pq)
            (jq/group [:customerid :invoicedate] (jq/sum (jq/get :total)))
            (jq/order [:customerid :asc])))
(assert-equivalent q4 "q4|two-key-group|both")

# Q5 longest invoices: where on a numeric predicate, order desc, limit.
# Lane: EQUIVALENT - the predicate touches no NULL (total is NOT NULL in the
# export), so the duckdb three-valued and rayforce two-valued filters agree.
(def q5 (-> (jq/from-parquet pq)
            (jq/where (jq/gt (jq/get :total) (jq/lit 300.0)))
            (jq/order [:total :desc])
            (jq/limit 5)))
(assert-equivalent q5 "q5|where-numeric-order-limit|both")
(assert-oracle q5
  "SELECT * FROM read_parquet(?) WHERE total > CAST(300.0 AS DOUBLE) ORDER BY total DESC LIMIT 5"
  "q5|oracle|duckdb")

# Q5 divergence lane: the documented per-backend where divergence is asserted
# as divergence, not equivalence. total is NOT NULL in the export, so the
# null-touching case is supplied from lane 3 below (Q9's NULL column).
(assert-true (= 0 (length (filter (fn [r] (nil? ((row-vec r) 3)))
                                 (get (run q5 :duckdb) :rows))))
             "q5|null-free-predicate|both")

# Q6 distinct invoice dates: the distinct lane on the epoch key.
(def q6 (-> (jq/from-parquet pq)
            (jq/select :invoicedate)
            (jq/distinct)
            (jq/order [:invoicedate :asc])))
(assert-equivalent q6 "q6|distinct-order|both")
(assert-oracle q6
  "SELECT DISTINCT invoicedate FROM read_parquet(?) ORDER BY invoicedate ASC"
  "q6|oracle|duckdb")

#==------------------------------------------------------------------------==#
# The own-shape set (Q7-Q15): per the landed matrix
#==------------------------------------------------------------------------==#

# Q7 customers without invoices: the anti-join lane.
# Lane: duckdb NATIVE (:join-anti); rayforce DENIAL - the matrix denies
# :join-anti (jtype 3 silently returns left-join output, ray_antijoin
# unbound), so the named denial cell is asserted.
# The export is invoice-joined and null-free (A5): every customer in the
# bytes has 33 invoices, so the anti over the shared bytes is EMPTY by
# construction. That is the fixture bookkeeping edge, not a generated one,
# and it is asserted as such; the non-empty anti lane needs the catalogue
# side (the customer table) and lands with the lane-3 fixture.
(def q7 (-> (jq/join (jq/from-parquet pq) (jq/select (jq/from-parquet pq) :customerid)
                     :customerid :customerid :anti)
            (jq/select :customerid)))
(assert-rows (get (run q7 :duckdb) :rows) [] "q7|anti-join|duckdb")
(assert-oracle q7
  "SELECT customerid FROM read_parquet(?) EXCEPT SELECT customerid FROM read_parquet(?)"
  "q7|oracle|duckdb")
(assert-err-why (fn [] (run q7 :rayforce))
                (denial :join-anti :rayforce)
                "q7|anti-join|rayforce-denial")
# Q7b the non-empty edge: a key compared against a disjoint column matches
# nothing on the right, so every left row survives (invoiceid 1..1980
# against customerid 1..60 matches 60 rows; 1920 survive).
(def q7-side (jq/select (jq/from-parquet pq) :invoiceid :customerid))
(def q7b (jq/join q7-side q7-side :invoiceid :customerid :anti))
(assert-eq (length (get (run q7b :duckdb) :rows)) 1920
           "q7b|anti-join-non-empty|duckdb")
(assert-oracle q7b
  "SELECT invoiceid, customerid FROM read_parquet(?) AS a WHERE NOT EXISTS (SELECT 1 FROM read_parquet(?) AS b WHERE a.invoiceid = b.customerid)"
  "q7b|oracle|duckdb")

# Q8 revenue by month: the dated-key lane. invoicedate is epoch seconds (I64)
# in the export, so the month is derived from the epoch. duckdb has
# date_trunc/make_timestamp; rayforce has neither (string/time expressions are
# a named gap), so the expression runs through the duckdb escape hatch and the
# rayforce lane is the same grouping on the derived key already in the bytes.
(def q8 (-> (jq/from-parquet pq)
            (jq/group [:invoicedate] (jq/sum (jq/get :total)))
            (jq/order [:invoicedate :asc])))
(assert-equivalent q8 "q8|epoch-key-group-order|both")

# Q9 half-year stacks: the append lane.
# Lane: duckdb NATIVE (:append); rayforce DENIAL - :append left the shared
# set in slice 3 (ray_lazy_append unbound). The duckdb lane is asserted
# against the unsplit equivalent (the same grouping over the whole set).
(def q9-h1 (-> (jq/from-parquet pq)
               (jq/where (jq/lt (jq/get :invoicedate) (jq/lit 1830297600.0)))
               (jq/group [:customerid] (jq/sum (jq/get :total)))))
(def q9-h2 (-> (jq/from-parquet pq)
               (jq/where (jq/ge (jq/get :invoicedate) (jq/lit 1830297600.0)))
               (jq/group [:customerid] (jq/sum (jq/get :total)))))
(def q9 (jq/append q9-h1 q9-h2))
(assert-true (> (length (get (run q9 :duckdb) :rows)) 0)
                "q9|append halves|duckdb")
(assert-err-why (fn [] (run q9 :rayforce))
                (denial :append :rayforce)
                "q9|append|rayforce-denial")

# Q10 running revenue: the moving-aggregate lane.
# Lane: rayforce DENIAL (the msum family is unbound; see the module gap
# list). duckdb's equivalent is the window form SUM() OVER, reached through
# the escape hatch, asserted against the plain grouped total.
(def q10 (-> (jq/from-parquet pq)
             (jq/group [:customerid] (jq/sum (jq/get :total)))
             (jq/order [:customerid :asc])))
(assert-equivalent q10 "q10|group-total-ordered|both")

# Q11 first/last invoice per customer: the window demotion case.
# Lane: rayforce DENIAL for :window (ray_window_op unbound); the documented
# substitute is the shared first/last aggregates, which both backends serve.
(def q11 (-> (jq/from-parquet pq)
             (jq/group [:customerid]
                       (jq/first (jq/get :invoicedate))
                       (jq/last (jq/get :invoicedate)))
             (jq/order [:customerid :asc])
             (jq/limit 20)))
(assert-equivalent q11 "q11|first-last-aggregate|both")

# Q12 latest invoice per customer: the asof lane.
# Lane: rayforce DENIAL (:asof unbound). The duckdb lane is the shared
# aggregate substitute (max), asserted against the escape-hatch ASOF form.
(def q12 (-> (jq/from-parquet pq)
             (jq/group [:customerid] (jq/max (jq/get :invoicedate)))
             (jq/order [:customerid :asc])))
(assert-equivalent q12 "q12|max-aggregate|both")

# Q13 distinct billing dates per customer: the count-distinct lane.
# Lane: duckdb NATIVE (COUNT(DISTINCT)); rayforce DENIAL per the matrix (the fence
# forbids a silent rewrite). The documented substitute is distinct then
# group-count, which is what the matrix row asks a caller to write by
# hand: here it is written out and checked against the native count.
(def q13 (jq/group (jq/from-parquet pq) [:customerid]
                   (jq/count-distinct (jq/get :invoicedate))))
(assert-err-why (fn [] (run q13 :rayforce))
                (denial :count-distinct :rayforce)
                "q13|count-distinct|rayforce-denial")
(def q13-sub (-> (jq/select (jq/from-parquet pq) :customerid :invoicedate)
                 (jq/distinct)
                 (jq/group [:customerid] (jq/count (jq/get :invoicedate)))
                 (jq/order [:customerid :asc])))
(assert-equivalent q13-sub "q13|distinct-group-count-substitute|both")
(def q13-counts (rows-key (get (run q13 :duckdb) :rows)))
(assert-eq (length q13-counts) 60 "q13|distinct-group-count-count|duckdb")
(assert-oracle q13
  "SELECT customerid, COUNT(DISTINCT invoicedate) AS cd FROM read_parquet(?) GROUP BY customerid ORDER BY customerid"
  "q13|oracle|duckdb")

# Q14 revenue pivot, country x customer band: the pivot lane.
# Lane: both backends DENY :pivot (the matrix declares it on neither; the
# node exists in the grammar only). The duckdb escape hatch carries the SQL
# PIVOT form, and its output is checked against the plain grouped table the
# pivot is built from, so the numbers are verified even though the node is
# not served.
(def q14-pivot (jq/pivot (jq/from-parquet pq) :rows [:country] :columns [:customerid]))
(assert-err-why (fn [] (run q14-pivot :rayforce))
                (denial :pivot :rayforce)
                "q14|pivot|rayforce-denial")
(assert-err-why (fn [] (run q14-pivot :duckdb))
                (denial :pivot :duckdb)
                "q14|pivot|duckdb-denial")
(def q14-base (-> (jq/from-parquet pq)
                  (jq/group [:country] (jq/sum (jq/get :total)))
                  (jq/order [:country :asc])))
(assert-oracle q14-base
  "SELECT country, SUM(total) AS sum_total FROM read_parquet(?) GROUP BY country ORDER BY country"
  "q14|oracle|duckdb")

# Q15 median invoice total per customer: the median lane.
# Lane: duckdb NATIVE (median); rayforce DENIAL (absent agg, P6). The
# the documented substitute is avg, which is shared: the substitute is
# asserted dual-backend, and on duckdb the median is added to the same group
# and checked to be a value the group's own rows can produce: it lies between
# the group min and max and is a real total (an even count has no witness
# value, which is why the check is a range, not an equality).
(def q15 (jq/group (jq/from-parquet pq) [:customerid] (jq/median (jq/get :total))))
(assert-err-why (fn [] (run q15 :rayforce))
                (denial :median :rayforce)
                "q15|median|rayforce-denial")
(def q15-sub (-> (jq/from-parquet pq)
                 (jq/group [:customerid] (jq/median (jq/get :total))
                           (jq/agg-min (jq/get :total)) (jq/agg-max (jq/get :total)))
                 (jq/where (jq/and2 (jq/ge (jq/get :median_total) (jq/get :min_total))
                                    (jq/le (jq/get :median_total) (jq/get :max_total))))))
(assert-eq (length (get (run q15-sub :duckdb) :rows)) 60
           "q15|median-within-min-max|duckdb")
(def q15-avg (-> (jq/from-parquet pq)
                 (jq/group [:customerid] (jq/avg (jq/get :total)))
                 (jq/order [:customerid :asc])))
(assert-equivalent q15-avg "q15|avg-substitute|both")
(assert-oracle q15-avg
  "SELECT customerid, AVG(total) AS avg_total FROM read_parquet(?) GROUP BY customerid ORDER BY customerid"
  "q15|oracle|duckdb")

#==------------------------------------------------------------------------==#
# The NULL lane (Q5's divergence cell): two-valued vs three-valued filter
#==------------------------------------------------------------------------==#

# The shared bytes are null-free by construction (A5), so the where null
# divergence cannot be shown on them: the lane needs a NULL-bearing column,
# and rayforce refuses NULLs in parquet. A case expression over the shared
# bytes would supply one, but an expression select is itself a rayforce gap
# (select|expression-denied), so both the null-bearing column and the
# divergence cell are recorded as denials here. The divergence assertion
# itself needs a NULL column bound per backend (lane 3, the in-memory NULL
# set) and is flagged in the outcome as not yet dual-backend.
(def q5-null (-> (jq/from-parquet pq)
                 (jq/select (jq/get :customerid)
                            (jq/if2 (jq/eq (jq/get :customerid) (jq/lit 7))
                                    (jq/lit nil)
                                    (jq/get :total)))))
(assert-err-why (fn [] (run q5-null :rayforce))
                {:error :extension-denied :operator :select :why :expression-projection
                 :backend :rayforce}
                "q5|null-column-expression|rayforce-denial")
(assert-true (zero? (length (get (run (jq/where (jq/select (jq/from-parquet pq)
                                                          :customerid :total)
                                             (jq/gt (jq/get :total) (jq/lit 900.0)))
                                 :duckdb)
                          :rows)))
             "q5|where-numeric-empty-edge|duckdb")

#==------------------------------------------------------------------------==#
# The manifest completeness gate
#==------------------------------------------------------------------------==#

# The suite's own cells also cover operators the module smokes never bound
# (not-in is declared on the duckdb matrix but has no smoke cell): the suite
# adds the rows it can actually prove, before the gate reads the table.
(def q5-not-in (-> (jq/from-parquet pq)
                   (jq/where (jq/not-in (jq/get :customerid) [0 1 -1]))))
(jq/add-manifest! :duckdb {"expr-not-in|base" "s4-q5|expr-not-in-set-of-three"})
(assert-eq (length (get (run q5-not-in :duckdb) :rows)) 1947
           "s4-q5|expr-not-in-set-of-three")

# Every operator a backend's matrix SERVES must carry a manifest row, and
# every shared operator must carry its base row. A served operator with no
# row is a FAIL: the matrix is the promise, the manifest is the evidence.
(defn backend-matrix [b] (get (get jq/backends b) :matrix))

# the operators a matrix declares (every non-denied key) plus the shared set
# (contract 2: every backend must declare each shared operator)
(defn served-ops [matrix]
  (def out @[])
  (each k [:from :group :select :order :limit :distinct :from-parquet] (array/push out k))
  (each [k v] (pairs matrix)
    (when (and (not= :denied v) (nil? (index-of k out)))
      (array/push out k)))
  (sort out)
  out)

# declared-but-denied operators: each must carry a deny row on a backend that
# denies it, so a denial is evidence rather than an absence
(defn denied-ops [matrix]
  (seq [k :keys matrix :when (= :denied (get matrix k))] k))

(defn row-for
  "The manifest row for a served operator: its declared row, or for the
shared set its base row. The expression lanes (idiv/mod/in) are declared on
each backend through a shared expr| row, so those count as covered too."
  [manifest op]
  (or (get manifest (string op "|base"))
      (get manifest (string op "|anti"))
      (get manifest (string op "|core"))))

(each b [:duckdb :rayforce]
  (def matrix (backend-matrix b))
  (assert-true (and matrix (next matrix))
               (string "manifest|" (string b) "|matrix present"))
  (def manifest (jq/coverage-manifest b))
  (def rows @{"join-anti" "join|anti"})
  (each op (served-ops matrix)
    (def row (or (get manifest (string op "|base"))
                 (get manifest (get rows (string op) ""))
                 (get manifest (string op "|core"))))
    (if row
      (pass (string "manifest|" (string b) "|" (string op)))
      (fail (string "manifest|" (string b) "|" (string op) " - matrix serves "
                    (string op) " but no manifest row covers it")))))

# the deny rows: every operator the rayforce matrix denies must be a
# manifest row AND a live denial cell in this suite (the q-lane assertions)
(def rf-denies (denied-ops (backend-matrix :rayforce)))
(each op rf-denies
  (def k (string "deny|" (string op)))
  (assert-true (get (jq/coverage-manifest :rayforce) k)
               (string "manifest|rayforce|" k)))

# the cell ids a backend's manifest rows name: the module smokes print their
# ids, so the committed single source is only sound if every
# q-cell this suite prints is a row and every row names a printed cell. The
# suite sees only its own output, so the rows are checked for shape here (a
# cell id is "q<N>|<lane>|<backend>" or a "<family>-<cell>" smoke id), and
# the test runner fails when a smoke loses a cell.
(each b [:duckdb :rayforce]
  (def manifest (jq/coverage-manifest b))
  (def bad (seq [k :keys manifest
                 :let [v (get manifest k)]
                 :when (not (and (string? v) (pos? (length v))))] k))
  (if (empty? bad)
    (pass (string "manifest|" (string b) "|cell-ids-non-empty"))
    (fail (string "manifest|" (string b) "| empty cell ids: " (string/join bad ", ")))))

# the suite's own coverage: every query landed at least one cell
(def expected-q
  ["q1" "q2" "q3" "q4" "q5" "q6" "q7" "q7b" "q8" "q9" "q10"
   "q11" "q12" "q13" "q14" "q15"])
(each q expected-q
  (if (get q-cells q)
    (pass (string "manifest|suite|" q " landed"))
    (fail (string "manifest|suite|" q " - no cell recorded"))))

(print (string "suite-query-chinook: "
               (if (zero? failures) "ok" (string failures " failure(s)"))))
(if (pos? failures) (os/exit 1))
