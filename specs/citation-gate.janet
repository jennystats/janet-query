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
#                re-runs the CHEAP pinned commands (typecheck, one floor run,
#                the pins, intersection) and fails when one of them errors.
#                Bounded `quint verify` runs are NOT re-run here (each starts
#                an Apalache server, 15 s to minutes); their verdicts are
#                checked by verify.janet, and this gate requires that a
#                header stating such a verdict mark it STALE or leave it
#                unstated.
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
  (def pinned-state (run-pinned))
  (each [name state] (pairs pinned-state)
    (when (not (= state "ok"))
      (++ fails)
      (printf "  FAIL  pinned re-run %s: %s (a header verdict citing it is stale)" name state)))
  (def cs (cells header-lines-out))
  (printf "  %d verdict cell(s) read from the header" (length cs))
  (each [ctx line] cs
    (when (and (verify-ish? ctx line) (not (stale? ctx line))
               (or (not (nil? (string/find "GREEN" line)))
                   (not (nil? (string/find "RED" line)))))
      (++ fails)
      (printf "  FAIL  bounded-verify verdict stated live, not marked STALE: %s" (trimz line))))

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
