# run-examples.janet - run every example and print its output.
# Usage: CHINOOK=<parquet path> janet run-examples.janet
# AGPLv3, see LICENSE.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(def HERE (dirname (realpath ((dyn *args*) 0))))
(def FILES ["basic-select-filter.janet" "composition.janet" "joins.janet"
            "group-aggregate.janet" "loading-parquet-csv.janet"
            "catalogued-sources.janet" "errors.janet" "admission.janet"
            "raw-sql-vs-tree.janet"])

(each f FILES
  (printf "===== %s =====" f)
  (print (sh-capture (string "janet " (sh-quote (string HERE "/" f)))))
  (flush))
