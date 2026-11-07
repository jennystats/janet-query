# gen-data.janet - deterministic scale fixture for the janet-query benchmarks.
# Writes one parquet file: the eight Chinook-projection columns, null-free,
# PLAIN-encoded (the engine reader constraints recorded in the Chinook fixture
# README). Every route reads the same bytes. AGPLv3, see LICENSE.
# Usage: janet gen-data.janet [out-path] [rows]
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")
(import jennystats/duckdb :as dd)

(def SEED "20261107")
(def ARGS (script-args))
(def ROWS (if (> (length ARGS) 1) (scan-number (ARGS 1)) 65536))
(def OUT (if (> (length ARGS) 0) (ARGS 0)
             (string (dirname (realpath ((dyn *args*) 0)))
                     "/data/chinook-scale.parquet")))

(defn/typed sql-list {:args [:tuple] :ret :string} [xs]
  "A duckdb list literal from a tuple of strings."
  (string "[" (string/join (map |(string "'" $ "'") xs) ", ") "]"))

(def countries
  ["Argentina" "Australia" "Austria" "Belgium" "Brazil" "Canada" "Chile"
   "Czech Republic" "Denmark" "Finland" "France" "Germany" "Hungary" "India"
   "Ireland" "Italy" "Netherlands" "Norway" "Poland" "Portugal" "Spain"
   "Sweden" "United Kingdom" "United States"])

(def lastnames
  ["Adams" "Edwards" "Peacock" "Park" "Johnson" "Mitchell" "King" "Callahan"])

# Deterministic arithmetic only: the seed names the recipe, not a PRNG state.
# Default rows 65536: the rayforce parquet reader decodes at most 65536 rows
# per column (65537 raises "expected number or nil, got array"), so one shared
# file at that ceiling is the largest every route can read.
# Columns mirror test/fixtures/chinook/export.janet (BIGINT ids and epoch
# seconds, DOUBLE total, VARCHAR display strings), null-free.
(def sql
  (string "COPY (SELECT "
          "CAST(i + 1 AS BIGINT) AS invoiceid, "
          "CAST(1 + (i % 60) AS BIGINT) AS customerid, "
          "CAST(1262304000 + (i * 600) AS BIGINT) AS invoicedate, "
          "CAST(0.99 + ((i * 2971) % 2500) * 0.01 AS DOUBLE) AS total, "
          "CAST(" (sql-list countries) "[1 + ((i % 60) % 24)] AS VARCHAR) AS country, "
          "CAST(1 + ((i % 60) % 8) AS BIGINT) AS employeeid, "
          "CAST(CASE (1 + ((i % 60) % 8)) WHEN 1 THEN 0 "
          "ELSE 1 + ((1 + ((i % 60) % 8)) % 3) END AS BIGINT) AS reports_to, "
          "CAST(" (sql-list lastnames) "[1 + ((i % 60) % 8)] AS VARCHAR) AS lastname "
          "FROM range(" ROWS ") t(i)) TO " (sh-quote OUT)
          " (FORMAT parquet, COMPRESSION uncompressed, DICTIONARY_SIZE_LIMIT 0)"))

(def dir (dirname OUT))
(unless (os/stat dir) (os/mkdir dir))
(def db (dd/open ""))
(def conn (dd/connect db))
(dd/query conn sql)
(:close conn)
(:close db)

(def st (os/stat OUT))
(printf "seed=%s rows=%d bytes=%d" SEED ROWS (get st :size))
(print (string "sha256=" (string/trim (sh-capture (string "sha256sum " (sh-quote OUT))))))
