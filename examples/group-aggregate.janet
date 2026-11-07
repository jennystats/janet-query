# group-aggregate.janet - group, aggregate, order and limit on both engines.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def q (-> (jq/from-parquet P)
           (jq/group [:customerid] (jq/sum (jq/get :total)))
           (jq/order [:sum_total :desc] [:customerid :asc])
           (jq/limit 3)))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
