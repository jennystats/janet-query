# errors.janet - the refusal surface: a malformed node, an undeclared
# operator on a backend, and a query mixing two engines' handles.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))
(def src (jq/from-parquet P))

# 1. unknown node in a tree
(printf "unknown node: %s"
        (try (jq/execute {:node :pivot :input src} :backend :duckdb)
             ([e] (string/format "%q" e))))

# 2. an operator the backend does not declare
(def cd (jq/group src [:customerid] (jq/count-distinct (jq/get :invoicedate))))
(printf "count-distinct on rayforce: %s"
        (try (jq/execute cd :backend :rayforce) ([e] (string/format "%q" e))))

# 3. a tree whose two sides carry different engines' handles
(def mixed (jq/join (jq/from @{:backend :duckdb :handle 1})
                    (jq/from @{:backend :rayforce :handle 2}) :k :k))
(printf "mixed handles: %s"
        (try (jq/execute mixed :backend :duckdb) ([e] (string/format "%q" e))))
