# joins.janet - a left join with a grouped count, both engines.
# The sides are projected to their numeric columns: a side carrying a VARCHAR
# column is outside the rayforce join surface. Chinook's export gives every
# invoice row the same manager sentinel, so the left join is the lane that
# keeps rows here.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def invoices (jq/select (jq/from-parquet P) :invoiceid :reports_to))
(def managers (jq/distinct (jq/select (jq/from-parquet P) :employeeid)))

(def q (-> (jq/join invoices managers [:reports_to] [:employeeid] :left)
           (jq/group [:reports_to] (jq/count (jq/get :invoiceid)))
           (jq/order [:reports_to :asc])))

(each backend [:duckdb :rayforce]
  (printf "%s %q" backend (get (jq/execute q :backend backend) :rows)))
