# route-jq.janet - janet-query route for the cross-language benchmark.
# Usage: janet route-jq.janet <duckdb|rayforce> <cold|warm> <reps> [qid]
# Cold executes the tree against a from-parquet source (file read per run).
# Warm executes the same logic against a table loaded once: the duckdb lane
# against a table on the backend's own connection, the rayforce lane against
# a borrowed table handle.
# Emits LIB, MS and canonical ROW lines (see PROTOCOL.md). AGPLv3, see LICENSE.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/query :as jq)
(import jennystats/query-duckdb :as qd)
(import jennystats/query-rayforce)
(import jennystats/duckdb :as dd)
(import jennystats/rayforce :as rf)

(def ARGS (script-args))
(def BACKEND (keyword (ARGS 0)))
(def MODE (ARGS 1))
(def REPS (scan-number (ARGS 2)))
(def ONLY (if (> (length ARGS) 3) (ARGS 3) nil))
(def P (string (dirname (realpath ((dyn *args*) 0))) "/data/chinook-scale.parquet"))

(def KEYS ["invoiceid" "customerid" "invoicedate" "total" "country"
           "employeeid" "reports_to" "lastname"])

(defn env-of [tag]
  "One line of the resolved environment: KEY=value (empty when unset)."
  (printf "ENV %s %s" tag
          (string/join (seq [k :in KEYS] (string k "=" (or (os/getenv k) ""))) " ")))

(defn sha-of [path]
  "sha256 of a file's bytes (absent file named as such, not guessed)."
  (if (os/stat path)
    (string/trim (first (string/split " " (sh-capture (string "sha256sum " (sh-quote path))))))
    (string "MISSING:" path)))

(defn peak-kb []
  "Peak resident set size of this process, from /proc/self/status VmHWM."
  (var kb 0)
  (each line (string/split "\n" (string (slurp "/proc/self/status")))
    (when (string/has-prefix? "VmHWM:" line)
      (def parts (filter |(not (empty? $)) (string/split " " line)))
      (set kb (scan-number (get parts 1)))))
  kb)

(def COLS [:invoiceid :customerid :invoicedate :total :country :employeeid
           :reports_to :lastname])

(def qspec
  {"q1" [:int :float] "q2" [:int :float] "q3" [:int :int]
   "q4" [:int :int] "q5" [:int :int :float :float]})

(defn q1 [src]
  (-> src
      (jq/where (jq/gt (jq/get :total) (jq/lit 20.0)))
      (jq/select :invoiceid :total)
      (jq/order [:invoiceid :asc])
      (jq/limit 50)))

(defn q2 [src]
  (-> src
      (jq/group [:customerid] (jq/sum (jq/get :total)))
      (jq/order [:sum_total :desc] [:customerid :asc])
      (jq/limit 10)))

(defn q3 [src]
  (-> (jq/join (jq/select src :invoiceid :reports_to)
               (jq/distinct (jq/select src :employeeid))
               [:reports_to] [:employeeid])
      (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
      (jq/order [:reports_to :asc])))

(defn q4 [src]
  (-> (jq/join (jq/select src :customerid :invoicedate :invoiceid)
               (-> src (jq/group [:customerid] (jq/max (jq/get :invoicedate))))
               [:customerid :invoicedate] [:customerid :max_invoicedate])
      (jq/select :invoicedate :invoiceid)
      (jq/order [:invoiceid :asc])))

(defn q5 [src]
  (-> src
      (jq/group [:employeeid]
                (jq/count (jq/get :invoiceid))
                (jq/sum (jq/get :total))
                (jq/avg (jq/get :total)))
      (jq/order [:employeeid :asc])))

(def QS [["q1" q1] ["q2" q2] ["q3" q3] ["q4" q4] ["q5" q5]])

(defn fmt-val [kind v]
  (case kind
    :int (string/format "%.0f" v)
    :float (string/format "%.6f" v)))

(defn emit-rows [qid res]
  (def kinds (qspec qid))
  (def rws (get res :rows))
  (printf "QUERY %s ROWS %d" qid (length rws))
  (each r rws
    (printf "ROW %s %s" qid
            (string/join (seq [i :range [0 (length kinds)]]
                               (fmt-val (kinds i) (r i))) "|")))
  (flush))

(defn warm-source []
  (if (= BACKEND :duckdb)
    (do
      (dd/query (qd/conn)
                "CREATE OR REPLACE TABLE bench_t AS SELECT * FROM read_parquet(?)"
                [P])
      (jq/from :bench_t))
    (let [batches (rf/parquet-rows P)]
      (jq/from @{:backend :rayforce :handle (first batches)}))))

(defn exec [tree]
  (if (= BACKEND :duckdb)
    (jq/execute tree :backend BACKEND :catalog {:bench_t {:columns COLS}})
    (jq/execute tree :backend BACKEND)))

(printf "ROUTE jq-%s" BACKEND)
(printf "LIB janet-query %s"
        (if (= BACKEND :duckdb) "duckdb-1.5.6"
          (string "rayforce-" (string/join (map string (rf/engine-version)) "."))))
(def HERE (dirname (realpath ((dyn *args*) 0))))
(printf "MODULE query %s" (sha-of (string HERE "/../jennystats/query.janet")))
(printf "MODULE query-rayforce %s"
        (sha-of (string HERE "/../jennystats/query-rayforce.janet")))
(printf "MODULE rayforce %s" (sha-of (string HERE "/../libs/rayforce-module.janet")))
(env-of (if (= BACKEND :duckdb) "jq-duckdb" "jq-rayforce"))
(flush)

(def src (if (= MODE "warm") (warm-source) (jq/from-parquet P)))

(each [qid f] QS
  (when (or (nil? ONLY) (= ONLY qid))
    (def tree (f src))
    (var first-res nil)
    (when (= MODE "warm") (set first-res (exec tree)))
    (for _ 0 REPS
      (def t0 (os/clock))
      (def res (exec tree))
      (printf "MS %s %s %.3f" qid MODE (* 1000 (- (os/clock) t0)))
      (unless first-res (set first-res res)))
    (emit-rows qid first-res)
    (flush)))
(printf "PEAK %d" (peak-kb))
(flush)
