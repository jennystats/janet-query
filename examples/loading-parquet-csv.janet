# loading-parquet-csv.janet - the parquet source on both engines, and the
# refusal a CSV path meets: a from-node binds a parquet path, and there is no
# CSV reader in the query surface.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

(def parquet-q (jq/limit (jq/select (jq/from-parquet P) :invoiceid) 3))
(each backend [:duckdb :rayforce]
  (printf "%s parquet %q" backend (get (jq/execute parquet-q :backend backend) :rows)))

(def csv-q (jq/limit (jq/select (jq/from-parquet "chinook.csv") :invoiceid) 3))
(each backend [:duckdb :rayforce]
  (printf "%s csv %s" backend
          (try (string "served " (get (jq/execute csv-q :backend backend) :rows))
               ([e] (string "refused: " e)))))
