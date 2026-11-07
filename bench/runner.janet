# runner.janet - benchmark orchestrator (see PROTOCOL.md).
# Spawns each shipped route for both phases, parses machine-readable output,
# asserts output equivalence per query against the raw-SQL route, then prints
# the measured tables. Usage: janet runner.janet [reps]
# AGPLv3, see LICENSE.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(def ARGS (script-args))
(def REPS (if (> (length ARGS) 0) (scan-number (ARGS 0)) 5))
(def HERE (dirname (realpath ((dyn *args*) 0))))

(defn route-cmd [name mode reps]
  (def av (string " " mode " " reps))
  (case name
    "duckdb-sql" (string "janet " (sh-quote (string HERE "/route-duckdb-sql.janet")) av)
    "jq-duckdb" (string "janet " (sh-quote (string HERE "/route-jq.janet")) " duckdb" av)
    "jq-rayforce" (string "janet " (sh-quote (string HERE "/route-jq.janet")) " rayforce" av)
    (errorf "unknown route %s" name)))

(def ROUTES ["duckdb-sql" "jq-duckdb" "jq-rayforce"])
(def QUERIES ["q1" "q2" "q3" "q4" "q5"])

(defn empty-parsed []
  (def ms @{})
  (def rows @{})
  (def nrows @{})
  (each q QUERIES
    (put ms q @{})
    (put rows q @[])
    (put nrows q nil))
  @{:route "?" :lib "?" :ms ms :rows rows :nrows nrows})

(defn parse-route [text]
  (def p (empty-parsed))
  (each line (filter |(not (empty? $)) (string/split "\n" text))
    (def parts (string/split " " (string/trim line)))
    (case (get parts 0)
      "ROUTE" (put p :route (get parts 1))
      "LIB" (put p :lib (string/join (slice parts 1) " "))
      "MS" (let [qid (get parts 1) mode (keyword (get parts 2)) ms (scan-number (get parts 3))]
             (when (and ms (or (= mode :cold) (= mode :warm)))
               (def msq (get (get p :ms) qid))
               (def cell (or (get msq mode)
                             (do (put msq mode @[]) (get msq mode))))
               (array/push cell ms)))
      "QUERY" (put-in p [:nrows (get parts 1)] (scan-number (get parts 3)))
      "ROW" (array/push (get-in p [:rows (get parts 1)]) (get parts 2))
      nil))
  p)

(defn run-route [name mode reps]
  (def text (sh-capture (route-cmd name mode reps)))
  (def p (parse-route text))
  (unless (= name (get p :route))
    (errorf "%s/%s produced no ROUTE line - raw output:\n%s" name mode text))
  (each q QUERIES
    (def got (length (get (get p :rows) q)))
    (unless (= reps (length (get-in p [:ms q (keyword mode)] @[])))
      (errorf "%s/%s: %s has %d timed samples, expected %d\n%s"
              name mode q (length (get-in p [:ms q (keyword mode)] @[])) reps text))
    (unless (= got (or (get (get p :nrows) q) -1))
      (errorf "%s/%s: %s ROW lines %d != declared rows %v\n%s"
              name mode q got (get (get p :nrows) q) text)))
  p)

# -- warm-up pass (one invocation per route per phase, discarded) ------------
(each name ROUTES
  (each mode ["cold" "warm"]
    (run-route name mode 1)))

# -- measured pass -----------------------------------------------------------
(def data
  (seq [name :in ROUTES]
    (printf "running %-12s cold+warm x%d" name REPS)
    (flush)
    [name {:cold (run-route name "cold" REPS)
           :warm (run-route name "warm" REPS)}]))
(defn pair-of [name] (get (get (filter |(= name (get $ 0)) data) 0) 1))

# -- output equivalence gate (before any timing claim) ----------------------
(var equiv-ok true)
(each phase [:cold :warm]
  (def ref (get-in data [0 1 phase]))
  (each [name pair] (slice data 1)
    (each q QUERIES
      (def want (get (get ref :rows) q))
      (def got (get (get (get pair phase) :rows) q))
      (unless (deep= want got)
        (set equiv-ok false)
        (printf "EQUIV MISMATCH %s %s %s: ref %d rows, route %d rows"
                name (string phase) q (length want) (length got))
        (var shown 0)
        (for i 0 (min (length want) (length got))
          (unless (= (want i) (got i))
            (when (< shown 3)
              (printf "  first diff at %d: ref=%s got=%s" i (want i) (got i))
              (++ shown))))
        (when (> (length want) (length got))
          (printf "  ref extra rows from %d: %s" (length got)
                  (slice want (length got))))))))

# -- tables ------------------------------------------------------------------
(defn min-of [xs] (if (empty? xs) 0 (apply min xs)))
(defn cell-ms [pair mode q] (min-of (get-in pair [mode :ms q mode] @[])))
(defn fastest [mode q]
  (min-of (seq [p :in data] (cell-ms (get p 1) mode q))))

(defn table [mode]
  (printf "\n== %s (ms, min of %d) ==" mode REPS)
  (printf "%-5s %s" "query" (string/join (map |(string/format "%-12s" $) ROUTES) ""))
  (each q QUERIES
    (printf "%-5s %s" q
            (string/join
              (seq [name :in ROUTES]
                   (string/format "%-12.1f" (cell-ms (pair-of name) mode q)))
              "")))
  (printf "\n== %s ratio vs fastest ==" mode)
  (printf "%-5s %s" "query" (string/join (map |(string/format "%-12s" $) ROUTES) ""))
  (each q QUERIES
    (def fast (fastest mode q))
    (printf "%-5s %s" q
            (string/join
              (seq [name :in ROUTES]
                   (string/format "%-12.2f" (/ (cell-ms (pair-of name) mode q) fast)))
              ""))))

(table :cold)
(table :warm)

# -- versions and machine ----------------------------------------------------
(printf "\n== route versions ==")
(each [name pair] data
  (printf "%-12s %s" name (get (get pair :cold) :lib)))
(printf "\n== rows per query ==")
(def base (get-in data [0 1 :cold]))
(each q QUERIES (printf "%-3s %d" q (get (get base :nrows) q)))
(printf "\nmachine: %s / %s / %s"
        (string/trim (sh-capture "uname -m"))
        (string/trim (sh-capture "nproc"))
        (string/trim (sh-capture "/usr/bin/grep -m1 'model name' /proc/cpuinfo")))
(printf "date: %s" (sh-capture "date -u +%Y-%m-%dT%H:%M:%SZ"))
(printf "data: 65536 rows, sha256 2ef33afa8127b9fae96d94dbb502fbfadb0a20a4d48fc5ced8cb19c8a8b2cfee")

(unless equiv-ok
  (print "\nVERDICT: FAIL - output equivalence gate fired; timings are not a result")
  (os/exit 1))
(print "\nVERDICT: PASS - every route matched the raw-SQL row sets")
