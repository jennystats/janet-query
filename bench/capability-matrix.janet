# capability-matrix.janet - per-feature engine support, measured fresh.
# Every cell runs against the Chinook fixture bytes (the same file the query
# suite uses) and prints PASS/FAIL plus the measured value - the node
# classification and the documented exclusions, measured rather than
# asserted. AGPLv3, see LICENSE.
# Usage: janet capability-matrix.janet [parquet-path]
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def ARGS (script-args))
(def HERE (dirname (realpath ((dyn *args*) 0))))
(def P (if (> (length ARGS) 0) (ARGS 0)
           (string HERE "/../test/fixtures/chinook/chinook.parquet")))
(def TMP (string (or (os/getenv "TMPDIR") "/tmp") "/jq-cap-write.parquet"))

(var passed 0)
(var failed 0)

(defn/typed outcome {:args [:function] :ret :table} [f]
  (try @{:kind :serves :value (f)}
    ([e] @{:kind :denies :value e})))

(defn/typed cell {:args [:string :function :keyword] :ret :nil} [name f want]
  (def got (outcome f))
  (def ok (= (get got :kind) want))
  (if ok (++ passed) (++ failed))
  (printf "cell %-44s %s want=%s got=%q" name (if ok "PASS" "FAIL")
          (string want) got))

(defn deny-class [name f ekey &opt why]
  (def got (outcome f))
  (def v (get got :value))
  (def ok (and (= :denies (get got :kind))
               (= ekey (get v :error))
               (or (nil? why) (= why (get v :why)))))
  (if ok (++ passed) (++ failed))
  (printf "cell %-44s %s want=%s/%s got=%q" name (if ok "PASS" "FAIL")
          (string ekey) (if why (string why) "*") got))

(defn rows [q backend &opt cat]
  (get (jq/execute q :backend backend :catalog cat) :rows))

(defn cols [q cat]
  (get (jq/expand-tree q cat) :columns))

(def src (jq/from-parquet P))

# ---- loading ----
(cell "parquet/duckdb" (fn [] (length (rows (jq/limit src 3) :duckdb))) :serves)
(cell "parquet/rayforce" (fn [] (length (rows (jq/limit src 3) :rayforce))) :serves)

# CSV: a from-node binds a parquet path; the contract has no CSV reader.
(def csv (jq/from-parquet "/tmp/does-not-exist.csv"))
(cell "csv/duckdb" (fn [] (rows csv :duckdb)) :denies)
(cell "csv/rayforce" (fn [] (rows csv :rayforce)) :denies)
(printf "v csv-duckdb-outcome %q" (get (outcome (fn [] (rows csv :duckdb))) :value))
(printf "v csv-rayforce-outcome %q" (get (outcome (fn [] (rows csv :rayforce))) :value))

# ---- composition ----
(def stack (-> src
              (jq/where (jq/gt (jq/get :total) (jq/lit 10.0)))
              (jq/select :invoiceid :total)
              (jq/order [:invoiceid :asc])
              (jq/limit 5)))
(cell "composition-stack/duckdb" (fn [] (length (rows stack :duckdb))) :serves)
(cell "composition-stack/rayforce" (fn [] (length (rows stack :rayforce))) :serves)
(cell "distinct-numeric/duckdb" (fn [] (length (rows (jq/distinct (jq/select src :customerid)) :duckdb))) :serves)
(cell "distinct-numeric/rayforce" (fn [] (length (rows (jq/distinct (jq/select src :customerid)) :rayforce))) :serves)
(deny-class "distinct-str/rayforce"
            (fn [] (rows (jq/distinct (jq/select src :country)) :rayforce))
            :malformed-tree :rayforce-str-boundary)

# ---- joins (numeric keys) ----
# A join side carrying a VARCHAR column is refused by rayforce's renamed-copy
# strategy; projecting the side to numeric columns first serves on both lanes.
(def jraw (-> (jq/from-parquet P :alias :i)
              (jq/join (jq/from-parquet P :alias :m) [:reports_to] [:employeeid])
              (jq/select (jq/get :employeeid :m))))
(cell "join-raw-str-sides/duckdb" (fn [] (length (rows jraw :duckdb))) :serves)
(deny-class "join-raw-str-sides/rayforce" (fn [] (rows jraw :rayforce))
            :malformed-tree :rayforce-str-join-rename)
(def jinner (-> (jq/join (jq/select (jq/from-parquet P) :invoiceid :reports_to)
                         (jq/distinct (jq/select (jq/from-parquet P) :employeeid))
                         [:reports_to] [:employeeid])
                (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))))
(cell "join-inner/duckdb" (fn [] (length (rows jinner :duckdb))) :serves)
(cell "join-inner/rayforce" (fn [] (length (rows jinner :rayforce))) :serves)
(def jleft (-> (jq/join (jq/select (jq/from-parquet P) :invoiceid :reports_to)
                        (jq/distinct (jq/select (jq/from-parquet P) :employeeid))
                        [:reports_to] [:employeeid] :left)
               (jq/select :invoiceid :reports_to)
               (jq/limit 5)))
(cell "join-left/duckdb" (fn [] (length (rows jleft :duckdb))) :serves)
(cell "join-left/rayforce" (fn [] (length (rows jleft :rayforce))) :serves)
(def jfull (-> (jq/join (jq/select (jq/from-parquet P) :invoiceid :reports_to)
                        (jq/distinct (jq/select (jq/from-parquet P) :employeeid))
                        [:reports_to] [:employeeid] :full)
               (jq/select :invoiceid :reports_to)
               (jq/limit 5)))
(cell "join-full/duckdb" (fn [] (length (rows jfull :duckdb))) :serves)
(cell "join-full/rayforce" (fn [] (length (rows jfull :rayforce))) :serves)
(def janti (-> (jq/join (jq/select (jq/from-parquet P) :invoiceid :reports_to)
                        (jq/distinct (jq/select (jq/from-parquet P) :employeeid))
                        [:reports_to] [:employeeid] :anti)
               (jq/select :invoiceid)))
(cell "join-anti/duckdb" (fn [] (length (rows janti :duckdb))) :serves)
(deny-class "join-anti/rayforce" (fn [] (rows janti :rayforce)) :extension-denied nil)

# ---- aggregates ----
(def aggs (-> src
              (jq/group [:customerid]
                        (jq/sum (jq/get :total)) (jq/avg (jq/get :total))
                        (jq/count (jq/get :invoiceid)) (jq/min (jq/get :total))
                        (jq/max (jq/get :total)) (jq/first (jq/get :invoicedate))
                        (jq/last (jq/get :invoicedate)) (jq/stddev (jq/get :total))
                        (jq/var (jq/get :total)))))
(cell "group-aggregate-9/duckdb" (fn [] (length (rows aggs :duckdb))) :serves)
(cell "group-aggregate-9/rayforce" (fn [] (length (rows aggs :rayforce))) :serves)
(def cd (jq/group src [:customerid] (jq/count-distinct (jq/get :invoicedate))))
(cell "count-distinct/duckdb" (fn [] (length (rows cd :duckdb))) :serves)
(deny-class "count-distinct/rayforce" (fn [] (rows cd :rayforce)) :extension-denied nil)
(def med (jq/group src [:customerid] (jq/median (jq/get :total))))
(cell "median/duckdb" (fn [] (length (rows med :duckdb))) :serves)
(deny-class "median/rayforce" (fn [] (rows med :rayforce)) :extension-denied nil)
(def keyless (jq/group src [] (jq/count (jq/get :invoiceid)) (jq/sum (jq/get :total))))
(cell "keyless-group/duckdb" (fn [] (length (rows keyless :duckdb))) :serves)
(deny-class "keyless-group/rayforce" (fn [] (rows keyless :rayforce))
            :malformed-tree :rayforce-no-keys-group)

# ---- append / parquet write ----
(def half1 (jq/limit (jq/select src :invoiceid) 2))
(def half2 (jq/limit (jq/select src :invoiceid) 2))
(cell "append/duckdb" (fn [] (length (rows (jq/append half1 half2) :duckdb))) :serves)
(deny-class "append/rayforce" (fn [] (rows (jq/append half1 half2) :rayforce)) :extension-denied nil)
(def wr (jq/write-parquet (jq/select src :invoiceid) TMP))
(cell "write-parquet/duckdb" (fn [] (rows wr :duckdb)) :serves)
(deny-class "write-parquet/rayforce" (fn [] (rows wr :rayforce)) :extension-denied nil)
(when (os/stat TMP) (os/rm TMP))

# ---- the rayforce STR boundary ----
(def strgroup (jq/group src [:country] (jq/count (jq/get :invoiceid))))
(cell "str-group/rayforce" (fn [] (length (rows strgroup :rayforce))) :serves)
(deny-class "str-order-after-group/rayforce"
            (fn [] (rows (jq/order strgroup [:country :asc]) :rayforce))
            :malformed-tree :rayforce-str-boundary)
(def strjoin (-> (jq/from-parquet P :alias :i)
                 (jq/join (jq/from-parquet P :alias :m) [:reports_to] [:employeeid])
                 (jq/group [:lastname] (jq/count (jq/get :invoiceid :i)))))
(deny-class "str-join-rename/rayforce" (fn [] (rows strjoin :rayforce))
            :malformed-tree :rayforce-str-join-rename)

# ---- D2 cross-backend handle guard ----
(cell "d2-cross-backend-handles"
      (fn [] (rows (jq/join (jq/from @{:backend :duckdb :h 1})
                            (jq/from @{:backend :rayforce :h 2}) :k :k) :duckdb))
      :denies)
(deny-class "d2-cross-backend-class"
            (fn [] (rows (jq/join (jq/from @{:backend :duckdb :h 1})
                                  (jq/from @{:backend :rayforce :h 2}) :k :k) :duckdb))
            :malformed-tree :cross-backend-handles)

# ---- catalogued sources and the narrowed-C admission lane ----
(def cat {P {:columns [:invoiceid :total] :writer P}})
(def cat-src (jq/from-parquet P))
(cell "catalog/known-column-duckdb" (fn [] (length (rows (jq/select cat-src :total) :duckdb cat))) :serves)
(deny-class "catalog/unknown-column-duckdb"
            (fn [] (rows (jq/select cat-src :zzz) :duckdb cat)) :unknown-column nil)
(deny-class "catalog/unknown-column-rayforce"
            (fn [] (rows (jq/select cat-src :zzz) :rayforce cat)) :unknown-column nil)
# narrowed-C polarity (api-contract v1.1 change line 2026-11-06): a foreign
# writer describes the record at expansion; plain serves the listed names,
# the where form refuses an unlisted name.
(def narrow {P {:columns [:invoiceid :total] :writer "other.parquet"}})
(printf "v narrowed-c-plain %q" (cols (jq/select cat-src :total) narrow))
(cell "narrowed-c-plain-serves" (fn [] (cols (jq/select cat-src :total) narrow)) :serves)
(deny-class "narrowed-c-where-unlisted"
            (fn [] (cols (jq/where cat-src (jq/gt (jq/get :zzz) (jq/lit 1))) narrow))
            :unknown-column nil)

(printf "RESULT: %s passed=%d failed=%d"
        (if (zero? failed) "pass" "fail") passed failed)
(unless (zero? failed) (os/exit 1))
