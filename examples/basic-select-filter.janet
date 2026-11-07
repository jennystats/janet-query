# basic-select-filter.janet - filter, project, order, limit on both engines.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def q (-> (jq/from-parquet P)
           (jq/where (jq/gt (jq/get :total) (jq/lit 300.0)))
           (jq/select :invoiceid :total)
           (jq/order [:total :desc] [:invoiceid :asc])
           (jq/limit 5)))

(each backend [:duckdb :rayforce]
  (def res (jq/execute q :backend backend))
  (printf "%s columns=%q" backend (get res :columns))
  (each row (get res :rows) (printf "  %q" row)))
