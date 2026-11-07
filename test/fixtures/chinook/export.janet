# The fixture export: schema.sql -> the shared Parquet bytes both engines load.
# Column shapes follow the published Chinook schema (Lucas N. Goncalves, MIT
# licence). The recipe is deterministic: a rerun over the same schema.sql is
# byte-identical, and the suite re-verifies the sha256 recorded in README.md.
# Run from this directory: janet export.janet [out-dir]. See README.md.
#
# Codec pins (the A5/A13 rejection class - the rayforce parquet reader is the
# binding constraint; each pin below was verified by loading the bytes on both
# engines):
#   - INTEGER columns are CAST to BIGINT (the reader decodes I64 only; I32 is
#     deferred), DECIMAL to DOUBLE (only flat primitives are accepted);
#   - COMPRESSION uncompressed and DICTIONARY_SIZE_LIMIT 0 force PLAIN page
#     encoding (the reader rejects dictionary pages);
#   - no NULLs and no empty strings survive: the reader rejects null-bearing
#     columns and decodes an empty string as nil (a silent divergence from
#     duckdb). Null-able display strings are coalesced to a placeholder;
#   - timestamps become epoch seconds (I64) - the dated-key interchange shape.

(import jennystats/typed :prefix "")

(def dir
  "The scripts write in the current directory (run them from this folder;
an optional argument redirects a scratch rerun)."
  (or (and (> (length (dyn :args)) 1) ((dyn :args) 1)) "."))
(def schema (string dir "/schema.sql"))
(def db (string dir "/.build.duckdb"))
(def out (string dir "/chinook.parquet"))

(unless (os/stat schema)
  (errorf "missing %s - run `janet gen.janet` in %s first" schema dir))

(defn ddb [sql]
  "Run one duckdb statement on the build db; raise with its output on failure."
  (def log (string dir "/.duckdb.log"))
  (def f (file/open log :w))
  (def code (os/execute ["duckdb" db "-c" sql] :p {:out f}))
  (file/close f)
  (unless (zero? code)
    (errorf "duckdb failed (%d): %s" code (string (slurp log)))))

(when (os/stat db) (os/rm db))
(ddb (string ".read " schema))

# The 15 queries touch invoice, customer, track, genre, playlist,
# playlist_track and employee. One row per invoice line position keeps the
# id/measure columns the classic set groups on; display strings ride along only
# where a lane joins or groups on them (the STR slice).
#
# The employee columns ride on the invoice row through the customer's
# support representative, which is what makes the reporting chain (Q3) a
# self-join over these same bytes: each invoice row names the rep who
# owns the customer and that rep's manager. The chain's top employee has
# a NULL reports_to; a null-free export cannot carry it, so the
# projection names the sentinel 0 - the row survives, and the join to a
# manager with employeeid 0 matches nothing, so Q3's top exclusion is
# preserved rather than manufactured. Column names stay unprefixed so the
# alias-by-renamed-copy join shape applies on both backends.
(ddb (string/join
      ["COPY (SELECT"
       "    CAST(invoiceid AS BIGINT) AS invoiceid,"
       "    CAST(customerid AS BIGINT) AS customerid,"
       "    CAST(invoicedate AS BIGINT) AS invoicedate,"
       "    total,"
       "    country,"
       "    employeeid,"
       "    reports_to,"
       "    lastname"
       "  FROM (SELECT CAST(i.invoiceid AS BIGINT) AS invoiceid,"
       "               CAST(i.customerid AS BIGINT) AS customerid,"
       "               CAST(epoch(i.invoicedate) AS BIGINT) AS invoicedate,"
       "               CAST(i.total AS DOUBLE) AS total,"
       "               CAST(coalesce(NULLIF(c.country, ''), 'Unknown')"
       "                    AS VARCHAR) AS country,"
       "               CAST(e.employeeid AS BIGINT) AS employeeid,"
       "               CAST(coalesce(e.reportsto, 0) AS BIGINT) AS reports_to,"
       "               CAST(e.lastname AS VARCHAR) AS lastname"
       "        FROM invoice i JOIN customer c USING (customerid)"
       "          JOIN employee e ON c.supportrepid = e.employeeid"
       "        ORDER BY i.invoiceid)"
       (string ") TO '" out "' (FORMAT parquet, COMPRESSION uncompressed,"
               " DICTIONARY_SIZE_LIMIT 0);")]
      " "))

(print (string "wrote " out))
