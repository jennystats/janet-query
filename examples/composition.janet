# composition.janet - a stack of distinct, order and limit on both engines.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def q (-> (jq/from-parquet P)
           (jq/select :customerid)
           (jq/distinct)
           (jq/order [:customerid :asc])
           (jq/limit 5)))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
