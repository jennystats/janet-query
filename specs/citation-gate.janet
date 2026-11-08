# Citation-closure gate for the shipped specs.
#
# Two checks, both mechanical:
#
#   citations  - every NAME the spec header and verify.janet cite (a
#                --main/--init/--step/--invariant/--match value, a def-name
#                array entry, a (likewise ...) continuation) must be a
#                definition in the shipped modules. Zero tolerance: a name
#                the text cites and the model does not define fails here
#                (the s1Choice class).
#   currency   - every verdict word in the header's measurement lines
#                (GREEN / RED / pass) must belong to a citation whose text
#                marks it STALE (or a re-run this gate performs). The gate
#                re-runs the CHEAP pinned commands (typecheck, the floor run,
#                the pins, the mutant family, intersection) at the case count
#                the header claims, and fails when one errors or reports a
#                different count.
#
# BUDGET RULE (owner ruling 2026-11-08). The currency set is DEFAULT-ON and
# capped at 5 minutes total; the five commands below fit. Any addition over
# budget is a recorded gate amendment, never silent accretion. Long
# bounded-verify runs (the `quint verify --invariant=...` class) are NEVER
# currency-eligible: their currency lives in the records (verify.janet and
# the spec header's STALE marking), not in this gate. The currency half
# prints its elapsed time on every run, so drift against the budget is
# visible without a stopwatch.
#
# Usage: janet specs/citation-gate.janet             (from specs/)
#        janet specs/citation-gate.janet --control   (positive control: an
#                                                     injected stale citation
#                                                     must fail the gate)
#
# Exit: 0 closed, 1 open (a failed gate). Control mode exits 0 when the
# injected defect failed the gate.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(defn/typed cap {:args [:string] :ret :string} [cmd]
  (string (sh-capture (string cmd " 2>&1"))))

(defn/typed trimz {:args [:string] :ret :string} [s] (string/trim s))

(def qnt-files
  ["scope-model.qnt" "catalogue-record.qnt" "catalogue-shapes.qnt"
   "catalogue-partb.qnt" "intersection.qnt"])

(def name-bearing
  # the flags whose value is a definition name; every other flag carries a
  # bound, a seed, a file path or nothing
  ["--invariant" "--main" "--init" "--step" "--match"])

(def def-patterns
  ["module %s {" "pure def %s(" "pure def %s:" "def %s =" "def %s:"
   "val %s =" "val %s:" "run %s =" "action %s =" "action %s("])

(defn/typed defined? {:args [:string :string] :ret :boolean} [name src]
  (var found false)
  (each p def-patterns
    (when (not found)
      (when (not (nil? (string/find (string/format p name) src)))
        (set found true))))
  found)

(defn/typed strip-quotes {:args [:string] :ret :string} [s]
  (string/replace-all "`" "" (string/replace-all "'" "" (string/replace-all "\"" "" s))))

(defn/typed words {:args [:string] :ret :array} [s]
  (filter |(not (empty? $)) (string/split " " s)))

(defn/typed nameish? {:args [:string] :ret :boolean} [w]
  "could this token name a definition"
  (and (> (length w) 1)
       (nil? (index-of (string/slice w 0 1) "0123456789"))
       (not (string/has-prefix? "-" w))
       (not (string/has-prefix? "." w))
       (not (string/has-suffix? "\\" w))))

(defn/typed line-cites {:args [:string] :ret :array} [line]
  "the names one header line cites"
  (def out @[])
  (def ws (words (strip-quotes (string/replace-all "\\" " " line))))
  (var k 0)
  (while (< k (length ws))
    (def w (ws k))
    (when (string/has-prefix? "--" w)
      (def eq (string/find "=" w))
      (def flag (if eq (string/slice w 0 eq) w))
      (when (index-of flag name-bearing)
        (var v (if eq (string/slice w (+ eq 1)) (string/trim (get ws (+ k 1) ""))))
        (when (empty? v)
          (set v (string/trim (get ws (+ k 1) "")))
          (++ k))
        (when (nameish? v) (array/push out v))))
    (++ k))
  out)

(defn/typed array-cites {:args [:string] :ret :array} [line]
  "the names of a `(def present [A B C])` row"
  (def out @[])
  (def lb (string/find "[" line))
  (when lb
    (def inner (string/slice line (+ lb 1)))
    (def rb (or (string/find "]" inner) (length inner)))
    (each w (words (strip-quotes (string/slice inner 0 rb)))
      (when (nameish? w) (array/push out w))))
  out)

(defn/typed likewise-cites {:args [:string] :ret :array} [line]
  "`(likewise a, b, c)` continues the previous flag"
  (def out @[])
  (def p (string/find "likewise" line))
  (when p
    (def tail (string/replace-all ")" " " (string/replace-all "," " " (string/slice line (+ p 8)))))
    (each w (words (strip-quotes tail))
      (when (nameish? w) (array/push out w))))
  out)

(defn/typed cite-lines {:args [:array] :ret :array} [lines]
  "citations from a header: command lines, def arrays, likewise rows"
  (def out @[])
  (each line lines
    (def body (trimz line))
    (cond
      (string/has-prefix? "(def " body)
      (do (each v (array-cites body) (array/push out v))
          (each v (line-cites body) (array/push out v)))
      (or (string/has-prefix? "quint" body) (string/has-prefix? "//" body))
      (each v (line-cites body) (array/push out v)))
    (each v (likewise-cites body) (array/push out v)))
  out)

(defn/typed header-lines {:args [:string] :ret :array} [p]
  "the leading comment block of a .qnt file, trimmed"
  (def out @[])
  (var done false)
  (each line (string/split "\n" (string (slurp-string p)))
    (def t (trimz line))
    (when (not done)
      (if (or (string/has-prefix? "//" t) (empty? t))
        (array/push out t)
        (set done true))))
  out)

# ---- the pinned re-runs (cheap commands only) ----
# A header states a CELL COUNT for each pinned run ("2 of 2 pass, 10000 tests
# each", "15 of 15 pass"). The count is the currency check: a `--match`
# regex that still selects a RENAMED cell (the prefix survives) prints a
# green and proves nothing, so the re-run must report EXACTLY the claimed
# number of cases.
(def pinned
  [["typecheck-all"
    (string/join (seq [f :in qnt-files] (string "quint typecheck " f " && ")) "")
    0]
   ["scope-floor"
    "quint test --main=janetQueryScope --match='scope.*InMaterialisedModel' scope-model.qnt"
    15]
   ["catalogue-pins"
    "quint test --main=janetQueryCatalogue --match='cmSamePathOwnersKeepDistinctKeys|cmSamePathPairRowRefusesTheSharedText' scope-model.qnt"
    2]
   ["scope-mutant"
    "quint test --main=janetQueryScope --match='MutantReadsANextState' scope-model.qnt"
    15]
   ["intersection"
    "quint test --main=janetQueryIntersection --match=\"sharedQueryBothBackends|extensionDeniedNamed|conflictNeverExecutes|ambiguousNeverExecutes|demotionRecordsRevision|demotionUnaffectedNeedsNoRevision|duplicateRegisterRejected\" intersection.qnt"
    7]])

(defn/typed cases-in {:args [:string] :ret :number} [text]
  "the number of `passed` cases quint printed"
  (var n 0)
  (var i 0)
  (while true
    (def p (string/find "passed" text i))
    (if (nil? p) (break))
    (++ n)
    (set i (+ p 6)))
  n)

(defn/typed red-cases-in {:args [:string] :ret :number} [text]
  "the number of `failed after` cases quint printed (a designed-red family)"
  (var n 0)
  (var i 0)
  (while true
    (def p (string/find "failed after" text i))
    (if (nil? p) (break))
    (++ n)
    (set i (+ p 12)))
  n)

(defn/typed run-pinned {:args [] :ret :table} []
  (def out @{})
  (each [name cmd want] pinned
    (def text (cap cmd))
    (def bad (or (string/find "rror" text) (string/find "FAIL" text)
                 (string/find "failed" text)))
    (def got (if (not (nil? (string/find "Mutant" cmd))) (red-cases-in text) (cases-in text)))
    (def state
      (cond
        # the mutant family is DESIGNED red: an "Expect condition does not
        # hold" line is its verdict, not an error
        (and bad (nil? (string/find "MutantReadsANextState" cmd))) "error"
        (and (> want 0) (not (= got want))) (string "count " got " (claimed " want ")")
        "ok"))
    (put out name state)
    (printf "  re-run %-15s -> %s" name state))
  out)

 # The vocabularies the header uses for a verdict, written as the header
# writes them (the header also spells the state in caps or with a leading
# qualifier: a word list typed in one case misses the other).
(def verdict-words ["GREEN" "RED" "PASS" "FAIL" "pass" "red"])

(defn/typed cells {:args [:array] :ret :array} [lines]
  "[[ctx text] ...] for every line carrying a verdict word"
  (def out @[])
  (var prev "")
  (each line lines
    (var hit false)
    (each w verdict-words
      (when (not (nil? (string/find w line))) (set hit true)))
    (when hit (array/push out @[prev line]))
    (set prev line))
  out)

(defn/typed stale? {:args [:string :string] :ret :boolean} [ctx line]
  (or (not (nil? (string/find "STALE" line)))
      (not (nil? (string/find "STALE" ctx)))
      (not (nil? (string/find "MEASURE ON THIS LANE" line)))))

(defn/typed verify-ish? {:args [:string :string] :ret :boolean} [ctx line]
  (or (not (nil? (string/find "verify" ctx))) (not (nil? (string/find "verify" line)))))

# ---- the verbatim-green record, as the contract requires it (12.8) ----
# A GREEN stated over a bounded verify is a FACT only when its record carries
# four parts: the VERBATIM clause, the TREE hashes, the ENDPOINT and the RUN
# COUNT. The record is one line:
#   verbatim-green <name>: clause=<text>; tree=<file>=<hex8>[,<file>=<hex8>];
#   endpoint=<host:port>; runs=<n> green=<k>
# and the clause must match a definition line in the shipped modules.
(def green-marker "verbatim-green")

(defn/typed hex8? {:args [:string] :ret :boolean} [h]
  "a recorded hash is the first 8 hex digits of a sha256"
  (var all (and (= (length h) 8) true))
  (each c h
    (unless (not (nil? (string/find (string/from-bytes c) "0123456789abcdefABCDEF")))
      (set all false)))
  all)

(defn/typed part {:args [:string :string] :ret :string} [rec key]
  "the = value of one field in a verbatim-green record, or nil"
  (def kf (string key "="))
  (def p (string/find kf rec))
  (when p
    (def rest (string/slice rec (+ p (length kf))))
    (var e (length rest))
    (each sep [";" " "]
      (def q (string/find sep rest))
      (when (and q (< q e)) (set e q)))
    (string/slice rest 0 e)))

(defn/typed clause-in-modules? {:args [:string :string] :ret :boolean} [clause all-src]
  "the verbatim clause names a definition the shipped modules carry"
  (and (not (empty? clause)) (not (nil? (string/find clause all-src)))))

(defn/typed green-claim-ok? {:args [:string :string :string] :ret :any} [line ctx all-src]
  "why a GREEN line over a bounded verify is not supported, or nil when the
   line is not such a claim / its record carries all four parts"
  (if (not (and (verify-ish? ctx line) (not (nil? (string/find "GREEN" line)))))
    nil
    (if (or (stale? ctx line)
            (and (not (nil? (string/find "STALE" line)))
                 (not (nil? (string/find green-marker line)))))
      nil
      (do
        (def p (string/find green-marker line))
        (if (nil? p)
          (string "no verbatim-green record (needs clause, tree hash, endpoint, run count): " (trimz line))
          (do
            (def rec (string/slice line p))
            (def clause (part rec "clause"))
            (def tree (part rec "tree"))
            (def endpoint (part rec "endpoint"))
            (def runs (part rec "runs"))
            (def green (part rec "green"))
            (def why
              (cond
                (or (nil? clause) (not (clause-in-modules? clause all-src))) "clause absent or names no shipped definition"
                (nil? tree) "tree hash absent"
                (nil? endpoint) "endpoint absent"
                (or (nil? runs) (nil? (scan-number runs))) "run count absent"
                (or (nil? green) (nil? (scan-number green))) "green count absent"
                ""))
            (if (empty? why) nil (string why ": " (trimz line)))))))))

(defn/typed run-gate {:args [:string :boolean] :ret :number} [root control]
  (var fails 0)
  (def all-src (string/join (seq [f :in qnt-files] (string (slurp-string (string root "/" f)))) "\n"))
  (def header-lines-out @[])
  (each f ["scope-model.qnt" "intersection.qnt"]
    (each l (header-lines (string root "/" f)) (array/push header-lines-out l)))
  (when control
    (array/push header-lines-out "// quint verify --invariant=controlStaleName scope-model.qnt"))
  (def verify-lines (string/split "\n" (string (slurp-string (string root "/verify.janet")))))
  (each l verify-lines (array/push header-lines-out l))

  (print "===== citation existence")
  (def cited (cite-lines header-lines-out))
  (var n 0)
  (def skipped @[])
  (each name cited
    # a `--match` value is a REGEX over run names (`.*`, `scope.*X`, and the
    # pin pair joined by `|`): the pinned runs check it, not the definition
    # scan. A `*Foo` token is the header's abbreviation of the mutant family
    # (`*MutantReadsANextState`), not a citation of one name.
    (if (or (not (nil? (string/find "*" name)))
            (not (nil? (string/find "|" name)))
            (not (nil? (string/find "\n" name)))
            (not (nil? (string/find "Mutant" name))))
      (array/push skipped name)
      (do
        (++ n)
        (unless (= name "verify")
          (unless (defined? name all-src)
            (++ fails)
            (printf "  FAIL  citation %s: no such definition in the shipped modules" name))))))
  (printf "  %d citation name(s) checked (%d regex/bound token(s) routed to the pinned runs)"
          n (length skipped))
  (when (< n 1)
    (++ fails)
    (print "  FAIL  the citation scan read no names at all (a zero-existence pass is not a pass)"))

  (print "===== verdict currency")
  (def t0 (os/clock))
  (def pinned-state (run-pinned))
  (def elapsed (- (os/clock) t0))
  (each [name state] (pairs pinned-state)
    (when (not (= state "ok"))
      (++ fails)
      (printf "  FAIL  pinned re-run %s: %s (a header verdict citing it is stale)" name state)))
  # budget visibility: the currency set is capped at 5 minutes (owner ruling
  # 2026-11-08); an addition past it is a recorded gate amendment, never
  # silent accretion
  (printf "  currency half elapsed: %.1fs (budget %ds, %s)"
          elapsed 300 (if (<= elapsed 300) "within" "OVER BUDGET"))
  (when (> elapsed 300)
    (++ fails)
    (print "  FAIL  currency set is over the 300 s budget - amend the gate, do not accrete"))
  (def cs (cells header-lines-out))
  (printf "  %d verdict cell(s) read from the header" (length cs))
  (each [ctx line] cs
    (when (and (verify-ish? ctx line) (not (stale? ctx line))
               (or (not (nil? (string/find "GREEN" line)))
                   (not (nil? (string/find "RED" line)))))
      (++ fails)
      (printf "  FAIL  bounded-verify verdict stated live, not marked STALE: %s" (trimz line)))
    (def why (green-claim-ok? line ctx all-src))
    (when why
      (++ fails)
      (printf "  FAIL  %s" why)))

  (print "===== verbatim-green records")
  (def green-lines (filter |(not (nil? (string/find green-marker $))) header-lines-out))
  (each line green-lines
    (def why (green-claim-ok? line "verify" all-src))
    (if why
      (do (++ fails) (printf "  FAIL  verbatim-green record incomplete: %s" why))
      (printf "  record ok: %s" (trimz line))))
  (printf "  %d verbatim-green record(s) carried" (length green-lines))

  (printf "\n%s: %d failure(s)"
          (if (= fails 0) (if control "CONTROL PASSED" "CLOSED") "OPEN") fails)
  fails)

(def control (= (first (script-args)) "--control"))
(unless (os/stat "scope-model.qnt")
  (error "run from the specs/ directory"))
(def fails (run-gate "." control))
(if control
  (when (= fails 0) (error "control did not fail the gate"))
  (when (> fails 0) (os/exit 1)))
