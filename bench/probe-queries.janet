# probe-queries.janet - freeze the benchmark query shapes on both lanes.
# Prints row counts and the first rows per query per lane, then the raw-SQL
# reference rows. Read-only; no timing. AGPLv3, see LICENSE.
# Usage: janet probe-queries.janet [data-path] [qid]
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as dd)
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def ARGS (script-args))
(def P (if (> (length ARGS) 0) (ARGS 0)
           (string (dirname (realpath ((dyn *args*) 0))) "/data/chinook-scale.parquet")))
(def ONLY (if (> (length ARGS) 1) (ARGS 1) nil))

(defn q1 [p]
  (-> (jq/from-parquet p)
      (jq/where (jq/gt (jq/get :total) (jq/lit 20.0)))
      (jq/select :invoiceid :total)
      (jq/order [:invoiceid :asc])
      (jq/limit 50)))

(defn q2 [p]
  (-> (jq/from-parquet p)
      (jq/group [:customerid] (jq/sum (jq/get :total)))
      (jq/order [:sum_total :desc] [:customerid :asc])
      (jq/limit 10)))

(defn q3 [p]
  (def managers (jq/distinct (jq/select (jq/from-parquet p) :employeeid)))
  (-> (jq/join (jq/select (jq/from-parquet p) :invoiceid :reports_to)
               managers
               [:reports_to] [:employeeid])
      (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
      (jq/order [:reports_to :asc])))

(defn q4 [p]
  (def latest
    (-> (jq/from-parquet p)
        (jq/group [:customerid] (jq/max (jq/get :invoicedate)))))
  (-> (jq/join (jq/select (jq/from-parquet p) :customerid :invoicedate :invoiceid)
               latest
               [:customerid :invoicedate] [:customerid :max_invoicedate])
      (jq/select :invoicedate :invoiceid)
      (jq/order [:invoiceid :asc])))

(defn q5 [p]
  (-> (jq/from-parquet p)
      (jq/group [:employeeid]
                (jq/count (jq/get :invoiceid))
                (jq/sum (jq/get :total))
                (jq/avg (jq/get :total)))
      (jq/order [:employeeid :asc])))

(def QS [["q1" q1] ["q2" q2] ["q3" q3] ["q4" q4] ["q5" q5]])

(defn show [tag res]
  (printf "%-18s cols=%v rows=%d" tag (get res :columns) (length (get res :rows)))
  (each r (take 4 (get res :rows)) (printf "  %q" r))
  (flush))

(each [name f] QS
  (when (or (nil? ONLY) (= ONLY name))
    (def tree (f P))
    (each backend [:duckdb :rayforce]
      (def t0 (os/clock))
      (def res (try (jq/execute tree :backend backend)
                    ([e] {:error e})))
      (def ms (* 1000 (- (os/clock) t0)))
      (if (get res :error)
        (printf "%-18s ERROR %.1fms %q" (string name "/" backend) ms (get res :error))
        (printf "%-18s %.1fms" (string name "/" backend) ms))
      (unless (get res :error) (show (string name "/" backend) res))
      (flush))))
