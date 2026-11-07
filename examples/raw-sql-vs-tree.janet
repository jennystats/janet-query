# raw-sql-vs-tree.janet - the same query as raw SQL on the duckdb binding and
# as a janet-query tree, with identical rows.
# Set CHINOOK to the Chinook parquet path. AGPLv3, see LICENSE.
(import jennystats/query :as jq)
(import jennystats/query-duckdb)
(import jennystats/duckdb :as dd)

(def P (or (os/getenv "CHINOOK") "chinook.parquet"))

# raw SQL through the duckdb binding
(def db (dd/open ""))
(def conn (dd/connect db))
(def sql (string "SELECT customerid, SUM(total) AS sum_total "
                 "FROM read_parquet(?) GROUP BY customerid "
                 "ORDER BY sum_total DESC, customerid ASC LIMIT 3"))
(def raw (with [r (dd/query conn sql [P])] (dd/rows r false :tuple)))
(:close conn)
(:close db)

# the same query as a tree
(def tree (-> (jq/from-parquet P)
              (jq/group [:customerid] (jq/sum (jq/get :total)))
              (jq/order [:sum_total :desc] [:customerid :asc])
              (jq/limit 3)))
(def rows (get (jq/execute tree :backend :duckdb) :rows))

(printf "raw SQL: %q" raw)
(printf "tree:    %q" rows)
(printf "identical: %v" (deep= (map |(tuple ;$) raw) rows))
