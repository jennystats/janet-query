# route-q6.janet - q6 lanes for the recorded ten-route comparison.
# q6 is in the recorded tables but not in the shipped route-jq.janet (v1 node
# set there: five queries, q1-q5). This file carries q6 on both janet-query
# backends so the tables' q6 cells can be re-measured on the same stack.
# Usage: janet route-q6.janet <duckdb|rayforce> <cold|warm> <reps>
# Emits ROUTE, LIB, MODULE, ENV, MS and canonical ROW lines (see PROTOCOL.md).
# AGPLv3, see LICENSE.
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
(def P (or (os/getenv "JQ_BENCH_FILE")
           (string (dirname (realpath ((dyn *args*) 0)))
                   "/data/chinook-scale.parquet")))

(def COLS [:invoiceid :customerid :invoicedate :total :country :employeeid
           :reports_to :lastname])

(def KEYS ["invoiceid" "customerid" "invoicedate" "total" "country"
           "employeeid" "reports_to" "lastname"])

(defn peak-kb []
  "Peak resident set size of this process, from /proc/self/status VmHWM."
  (var kb 0)
  (each line (string/split "\n" (string (slurp "/proc/self/status")))
    (when (string/has-prefix? "VmHWM:" line)
      (def parts (filter |(not (empty? $)) (string/split " " line)))
      (set kb (scan-number (get parts 1)))))
  kb)

(defn env-of [tag]
  "One line of the resolved environment: KEY=value (empty when unset)."
  (printf "ENV %s %s" tag
          (string/join
            (seq [k :in KEYS] (string k "=" (or (os/getenv k) "")))
            " ")))

(defn sha-of [path]
  "sha256 of a file's bytes (absent file named as such, not guessed)."
  (if (os/stat path)
    (string/trim (first (string/split " " (sh-capture (string "sha256sum " (sh-quote path))))))
    (string "MISSING:" path)))

(defn q6 [src]
  (-> src
      (jq/group [:invoicedate]
                (jq/count (jq/get :invoiceid))
                (jq/sum (jq/get :total)))
      (jq/order [:sum_total :desc] [:invoicedate :asc])
      (jq/limit 10)))

(defn fmt-val [kind v]
  (case kind
    :int (string/format "%.0f" v)
    :float (string/format "%.6f" v)))

(defn emit-rows [res]
  (def kinds [:int :int :float])
  (def rws (get res :rows))
  (printf "QUERY q6 ROWS %d" (length rws))
  (each r rws
    (printf "ROW q6 %s"
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

(def HERE (dirname (realpath ((dyn *args*) 0))))
(printf "ROUTE jq-%s" BACKEND)
(printf "LIB janet-query %s"
        (if (= BACKEND :duckdb) "duckdb-1.5.6"
          (string "rayforce-" (string/join (map string (rf/engine-version)) "."))))
(printf "MODULE query %s" (sha-of (string HERE "/../jennystats/query.janet")))
(printf "MODULE query-rayforce %s"
        (sha-of (string HERE "/../jennystats/query-rayforce.janet")))
(printf "MODULE rayforce %s" (sha-of (string HERE "/../libs/rayforce-module.janet")))
(env-of (if (= BACKEND :duckdb) "jq-duckdb" "jq-rayforce"))
(flush)

(def src (if (= MODE "warm") (warm-source) (jq/from-parquet P)))

(def tree (q6 src))
(var first-res nil)
(when (= MODE "warm") (set first-res (exec tree)))
(for _ 0 REPS
  (def t0 (os/clock))
  (def res (exec tree))
  (printf "MS q6 %s %.3f" MODE (* 1000 (- (os/clock) t0)))
  (unless first-res (set first-res res)))
(emit-rows first-res)
(printf "PEAK %d" (peak-kb))
(flush)
