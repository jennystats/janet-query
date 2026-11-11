# route-duckdb-sql.janet - raw SQL through jennystats/duckdb (reference route).
# Usage: janet route-duckdb-sql.janet <cold|warm> <reps> [qid]
# Cold reads the parquet in each statement; warm queries a table built once on
# the held connection. Emits LIB, MS and canonical ROW lines (PROTOCOL.md).
# AGPLv3, see LICENSE.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as dd)

(def ARGS (script-args))
(def MODE (ARGS 0))
(def REPS (scan-number (ARGS 1)))
(def ONLY (if (> (length ARGS) 2) (ARGS 2) nil))
(def P (string (dirname (realpath ((dyn *args*) 0))) "/data/chinook-scale.parquet"))

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
            (seq [k :in ["invoiceid" "customerid" "invoicedate" "total" "country"
                         "employeeid" "reports_to" "lastname"]]
                 (string k "=" (or (os/getenv k) "")))
            " ")))

(def qspec
  {"q1" [:int :float] "q2" [:int :float] "q3" [:int :int]
   "q4" [:int :int] "q5" [:int :int :float :float] "q6" [:int :int :float]})

(def FRESH
  {"q1" (string "SELECT invoiceid, total FROM read_parquet(?) "
                "WHERE total > 20.0 ORDER BY invoiceid ASC LIMIT 50")
   "q2" (string "SELECT customerid, SUM(total) AS sum_total FROM read_parquet(?) "
                "GROUP BY customerid ORDER BY sum_total DESC, customerid ASC LIMIT 10")
   "q3" (string "WITH m AS (SELECT DISTINCT employeeid FROM read_parquet(?)) "
                "SELECT i.reports_to, COUNT(i.invoiceid) AS count_invoiceid "
                "FROM read_parquet(?) i JOIN m ON i.reports_to = m.employeeid "
                "GROUP BY i.reports_to ORDER BY i.reports_to ASC")
   "q4" (string "WITH latest AS (SELECT customerid, MAX(invoicedate) AS max_invoicedate "
                "FROM read_parquet(?) GROUP BY customerid) "
                "SELECT i.invoicedate, i.invoiceid FROM read_parquet(?) i "
                "JOIN latest ON i.customerid = latest.customerid "
                "AND i.invoicedate = latest.max_invoicedate "
                "ORDER BY i.invoiceid ASC")
   "q5" (string "SELECT employeeid, COUNT(invoiceid) AS count_invoiceid, "
                "SUM(total) AS sum_total, AVG(total) AS avg_total "
                "FROM read_parquet(?) GROUP BY employeeid ORDER BY employeeid ASC")
   "q6" (string "SELECT invoicedate, COUNT(invoiceid) AS count_invoiceid, "
                "SUM(total) AS sum_total FROM read_parquet(?) "
                "GROUP BY invoicedate ORDER BY sum_total DESC, invoicedate ASC LIMIT 10")})

(def HELD
  {"q1" (string "SELECT invoiceid, total FROM bench_t "
                "WHERE total > 20.0 ORDER BY invoiceid ASC LIMIT 50")
   "q2" (string "SELECT customerid, SUM(total) AS sum_total FROM bench_t "
                "GROUP BY customerid ORDER BY sum_total DESC, customerid ASC LIMIT 10")
   "q3" (string "SELECT i.reports_to, COUNT(i.invoiceid) AS count_invoiceid "
                "FROM bench_t i JOIN (SELECT DISTINCT employeeid FROM bench_t) m "
                "ON i.reports_to = m.employeeid "
                "GROUP BY i.reports_to ORDER BY i.reports_to ASC")
   "q4" (string "WITH latest AS (SELECT customerid, MAX(invoicedate) AS max_invoicedate "
                "FROM bench_t GROUP BY customerid) "
                "SELECT i.invoicedate, i.invoiceid FROM bench_t i "
                "JOIN latest ON i.customerid = latest.customerid "
                "AND i.invoicedate = latest.max_invoicedate "
                "ORDER BY i.invoiceid ASC")
   "q5" (string "SELECT employeeid, COUNT(invoiceid) AS count_invoiceid, "
                "SUM(total) AS sum_total, AVG(total) AS avg_total "
                "FROM bench_t GROUP BY employeeid ORDER BY employeeid ASC")
   "q6" (string "SELECT invoicedate, COUNT(invoiceid) AS count_invoiceid, "
                "SUM(total) AS sum_total FROM bench_t "
                "GROUP BY invoicedate ORDER BY sum_total DESC, invoicedate ASC LIMIT 10")})

(defn params-for [qid]
  "Statement parameters for the cold lane: q3 and q4 read the file twice."
  (case qid "q3" [P P] "q4" [P P] [P]))

(defn fmt-val [kind v]
  (case kind
    :int (string/format "%.0f" v)
    :float (string/format "%.6f" v)))

(var db* nil)
(var conn* nil)
(defn conn []
  (unless conn*
    (set db* (dd/open ""))
    (set conn* (dd/connect db*)))
  conn*)

(defn exec-one [qid]
  (if (= MODE "warm")
    (with [r (dd/query (conn) (HELD qid))]
      (dd/rows r false :tuple))
    (with [r (dd/query (conn) (FRESH qid) (params-for qid))]
      (dd/rows r false :tuple))))

(defn emit-rows [qid rws]
  (def kinds (qspec qid))
  (printf "QUERY %s ROWS %d" qid (length rws))
  (each r rws
    (printf "ROW %s %s" qid
            (string/join (seq [i :range [0 (length kinds)]]
                               (fmt-val (kinds i) (r i))) "|")))
  (flush))

(printf "ROUTE duckdb-sql")
(printf "LIB janet-duckdb %s" (dd/library-version))
(env-of "duckdb-sql")
(flush)

(when (= MODE "warm")
  (dd/query (conn) "CREATE OR REPLACE TABLE bench_t AS SELECT * FROM read_parquet(?)" [P]))

(each qid ["q1" "q2" "q3" "q4" "q5" "q6"]
  (when (or (nil? ONLY) (= ONLY qid))
    (var first-rows nil)
    (when (= MODE "warm") (set first-rows (exec-one qid)))
    (for _ 0 REPS
      (def t0 (os/clock))
      (def rws (exec-one qid))
      (printf "MS %s %s %.3f" qid MODE (* 1000 (- (os/clock) t0)))
      (unless first-rows (set first-rows rws)))
    (emit-rows qid first-rows)
    (flush)))
(printf "PEAK %d" (peak-kb))
(flush)
