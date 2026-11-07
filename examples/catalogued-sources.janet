# catalogued-sources.janet - a catalog describes a source's columns, so an
# unknown column is refused at the tree pass instead of reaching the engine.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/query-rayforce)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))
(def catalog {P {:columns [:invoiceid :customerid :invoicedate :total
                           :country :employeeid :reports_to :lastname]
                 :writer P}})

(def known-q (jq/limit (jq/select (jq/from-parquet P) :invoiceid :total) 2))
(def unknown-q (jq/select (jq/from-parquet P) :region))

(each backend [:duckdb :rayforce]
  (printf "%s known %q" backend
          (get (jq/execute known-q :backend backend :catalog catalog) :rows))
  (printf "%s unknown %s" backend
          (try (string (get (jq/execute unknown-q :backend backend :catalog catalog) :rows))
               ([e] (string "refused: " (string/format "%q" e))))))
