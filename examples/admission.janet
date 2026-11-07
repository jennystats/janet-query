# admission.janet - catalogue admission: when an entry names a different
# writer, the described set still serves a plain read of its listed columns,
# and an unlisted name is refused at the where lane.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))
(def catalog {P {:columns [:invoiceid :total] :writer "another.parquet"}})
(def src (jq/from-parquet P))

(printf "plain select columns: %q"
        (get (jq/expand-tree (jq/select src :total) catalog) :columns))
(printf "plain select execute: %q"
        (get (jq/execute (jq/limit (jq/select src :total) 2) :backend :duckdb
                         :catalog catalog) :rows))
(printf "where on an unlisted column: %s"
        (try (jq/expand-tree (jq/where src (jq/gt (jq/get :zzz) (jq/lit 1))) catalog)
             ([e] (string/format "%q" e))))
