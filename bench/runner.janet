# runner.janet - benchmark orchestrator (see PROTOCOL.md).
# Spawns each shipped route for both phases, asserts output equivalence per
# query against the raw-SQL route, then prints the measured tables.
# Usage: janet runner.janet [reps]
# AGPLv3, see LICENSE.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(def ARGS (script-args))
(def REPS (if (> (length ARGS) 0) (scan-number (ARGS 0)) 5))
(def HERE (dirname (realpath ((dyn *args*) 0))))
(def STRICT (string (or (os/getenv "HOME") "") "/.local/bin/strict"))
(def BENCH-FILE (or (os/getenv "JQ_BENCH_FILE")
                    (string HERE "/data/chinook-scale.parquet")))

(defn route-cmd [name mode reps]
  (def av (string " " mode " " reps))
  (def s (string (sh-quote STRICT) " "))
  (case name
    "duckdb-sql" (string s (sh-quote (string HERE "/route-duckdb-sql.janet")) av)
    "jq-duckdb" (string s (sh-quote (string HERE "/route-jq.janet")) " duckdb" av)
    "jq-rayforce" (string s (sh-quote (string HERE "/route-jq.janet")) " rayforce" av)
    "q6-duckdb" (string s (sh-quote (string HERE "/route-q6.janet")) " duckdb" av)
    "q6-rayforce" (string s (sh-quote (string HERE "/route-q6.janet")) " rayforce" av)
    (errorf "unknown route %s" name)))

(def ROUTES ["duckdb-sql" "jq-duckdb" "jq-rayforce"])
(def QUERIES ["q1" "q2" "q3" "q4" "q5"])

(defn run-cmd [cmd target]
  "One lane invocation into target (2>&1). Returns the exit code."
  (os/execute ["/bin/sh" "-c"
               (string "JQ_BENCH_FILE=" (sh-quote BENCH-FILE) " " cmd
                       " > " (sh-quote target) " 2>&1")] :p))

(defn lane [name mode reps]
  "Discarded invocation, then the measured one. Returns the lane text: the
  route's own VmHWM read is appended by the route itself (PEAK line)."
  (def tmp (string "/tmp/bench-" (os/getpid) "-" name "-" mode))
  (unless (= 0 (run-cmd (route-cmd name mode "1") "/dev/null"))
    (errorf "%s/%s discard failed" name mode))
  (unless (= 0 (run-cmd (route-cmd name mode (string reps)) tmp))
    (errorf "%s/%s measured pass failed" name mode))
  (def text (string (slurp-string tmp)))
  (os/rm tmp)
  text)

(defn lines-of [text]
  (filter |(not (empty? $)) (string/split "\n" text)))

(defn entry [file key]
  "The text after KEY on the first line starting with it, or nil."
  (var v nil)
  (each line (lines-of file)
    (def parts (string/split " " (string/trim line)))
    (when (and (nil? v) (= key (get parts 0)))
      (set v (string/join (slice parts 1) " "))))
  v)

(defn samples [file]
  "qid -> [MS samples] from one lane output."
  (def out @{})
  (each line (lines-of file)
    (def parts (string/split " " (string/trim line)))
    (when (= "MS" (get parts 0))
      (def q (get parts 1))
      (def v (scan-number (get parts 3)))
      (when v (put out q (array/concat (get out q @[]) @[v])))))
  out)

(defn rowsets [file]
  "qid -> [ROW texts] from one lane output."
  (def out @{})
  (each line (lines-of file)
    (def parts (string/split " " (string/trim line)))
    (when (= "ROW" (get parts 0))
      (put out (get parts 1)
           (array/concat (get out (get parts 1) @[]) @[(get parts 2)]))))
  out)

(defn min-of [xs] (if (empty? xs) 0 (apply min xs)))
(defn same? [a b]
  (and a b (= (length a) (length b))
       (= 0 (length (filter (fn [i] (not= (a i) (b i))) (range (length a)))))))

(def lanes @{})

# -- warm-up pass (discarded) ------------------------------------------------
(each name ROUTES
  (each mode ["cold" "warm"]
    (lane name mode 1)))

# -- measured pass -----------------------------------------------------------
(each name ROUTES
  (each mode ["cold" "warm"]
    (printf "running %-12s %-4s x%d" name mode REPS)
    (flush)
    (put-in lanes [name mode] (lane name mode REPS))))

# q6: the shipped route emits q1-q5 only; route-q6.janet carries q6.
(each mode ["cold" "warm"]
  (printf "running q6 lanes %-4s x%d" mode REPS)
  (flush)
  (each backend ["q6-duckdb" "q6-rayforce"]
    (put-in lanes [backend mode] (lane backend mode REPS))))

# -- output equivalence gate (before any timing is reported) -----------------
(var equiv-ok true)
(each mode ["cold" "warm"]
  (def ref (rowsets (get-in lanes ["duckdb-sql" mode])))
  (each name ["jq-duckdb" "jq-rayforce"]
    (def got (rowsets (get-in lanes [name mode])))
    (each q QUERIES
      (unless (same? (get ref q) (get got q))
        (set equiv-ok false)
        (printf "EQUIV MISMATCH %s %s %s" name mode q))))
  (def ref6 (get ref "q6"))
  (each [name backend] [["jq-duckdb" "q6-duckdb"] ["jq-rayforce" "q6-rayforce"]]
    (unless (same? ref6 (get (rowsets (get-in lanes [backend mode])) "q6"))
      (set equiv-ok false)
      (printf "EQUIV MISMATCH %s %s q6" name mode))))

# -- tables ------------------------------------------------------------------
(defn cell [name mode q]
  (min-of (get (samples (get-in lanes
                                [(case q
                                   "q6" (case name "jq-duckdb" "q6-duckdb" "q6-rayforce")
                                    name) mode]))
                q @[])))

(defn table [mode]
  (printf "\n== %s (ms, min of %d) ==" mode REPS)
  (printf "%-5s %s" "query" (string/join (map |(string/format "%-12s" $) ROUTES) ""))
  (each q ["q1" "q2" "q3" "q4" "q5" "q6"]
    (printf "%-5s %s" q
            (string/join (seq [name :in ROUTES]
                              (string/format "%-12.1f" (cell name mode q))) ""))))

(table "cold")
(table "warm")

# -- versions and machine ----------------------------------------------------
(printf "\n== route versions ==")
(each name ROUTES
  (printf "%-12s %s" name (entry (get-in lanes [name "cold"]) "LIB")))
(printf "\n== rows per query ==")
(def refrows (rowsets (get-in lanes ["duckdb-sql" "cold"])))
(each q ["q1" "q2" "q3" "q4" "q5" "q6"]
  (printf "%-3s %d" q (length (get refrows q))))
(def sha (sh-capture (string "sha256sum " (sh-quote BENCH-FILE))))
(printf "\nmachine: %s / %s / %s"
        (string/trim (sh-capture "uname -m"))
        (string/trim (sh-capture "nproc"))
        (string/trim (sh-capture "grep -m1 'model name' /proc/cpuinfo")))
(printf "date: %s" (string/trim (sh-capture "date -u +%Y-%m-%dT%H:%M:%SZ")))
(printf "data: %s, sha256 %s"
        (or (os/getenv "JQ_BENCH_NOTE") "fixture")
        (first (string/split " " (string/trim sha))))

(unless equiv-ok
  (print "\nVERDICT: FAIL - output equivalence gate fired; timings are not a result")
  (os/exit 1))
(print "\nVERDICT: PASS - every route matched the raw-SQL row sets")
