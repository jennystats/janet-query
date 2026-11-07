# Regression cells for the citation-closure gate.
#
# Each cell plants a defect in a TEMP COPY of the specs tree and asserts the
# gate fails on it; the last cell asserts the shipped tree passes. The gate
# itself is never run against a mutation in place.
#
# Usage: janet specs/citation-gate-test.janet   (from specs/)
# Prints RESULT: pass / RESULT: fail.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(def files ["scope-model.qnt" "catalogue-record.qnt" "catalogue-shapes.qnt"
            "catalogue-partb.qnt" "intersection.qnt"
            "citation-gate.janet" "verify.janet"])

(defn/typed stage {:args [:string] :ret :string} [dir]
  "copy the spec files a gate run needs into dir"
  (each f files
    (spit (string dir "/" f) (string (slurp-string f))))
  dir)

(defn/typed fresh-dir {:args [:string] :ret :string} [tag]
  (def d (string "/tmp/citation-gate-" tag "-" (os/clock)))
  (os/mkdir d)
  d)

(defn/typed gate-rc {:args [:string :string] :ret :number} [dir extra]
  "run the gate in dir; returns its exit code"
  (def cmd (string "cd " (sh-quote dir) " && "
                   "JANET_PATH=\"$HOME/development/hot-tools/modules\" "
                   "~/.local/bin/janet citation-gate.janet " extra " > /dev/null 2>&1"))
  (sh cmd))

(defn/typed plant {:args [:string :string :string :string] :ret :nil}
  [dir file old new]
  (def p (string dir "/" file))
  (def t (string (slurp p)))
  (when (nil? (string/find old t)) (errorf "plant anchor missing in %s" file))
  (spit p (string/replace old new t)))

(var failures 0)
(defn/typed check {:args [:string :boolean] :ret :nil} [name ok]
  (if ok
    (print (string "  ok   " name))
    (do (++ failures) (print (string "  FAIL " name)))))

# cell 1: a citation whose name exists in no module
(def d1 (stage (fresh-dir "stale-cite")))
(plant d1 "verify.janet" "(def present [\"ps2Neutrality\""
       "(def present [\"s1Choice\" \"ps2Neutrality\"")
(check "stale invariant name fails the gate" (= 1 (gate-rc d1 "")))

# cell 2: a cited RUN one of the pinned commands selects, renamed out of
# the module (the gate must notice the name is gone)
(def d2 (stage (fresh-dir "renamed-run")))
(plant d2 "catalogue-record.qnt" "run cmSamePathOwnersKeepDistinctKeys = {"
       "run cmSamePathOwnersKeepDistinct = {")
(check "renamed run fails the gate" (= 1 (gate-rc d2 "")))

# cell 3: a header verdict citing a bounded verify, stated LIVE and not
# marked stale, must fail (the mechanical half of the errata chain: a
# verify verdict in the text with no re-run behind it)
(def d3 (stage (fresh-dir "unsupported-verdict")))
(plant d3 "scope-model.qnt" "//   (likewise absorptionNever, presenceNeverFlips)"
       "//   (likewise absorptionNever, presenceNeverFlips)\n//   quint verify --invariant=pbS2 GREEN is the present-mode result")
(check "live unsupported verify verdict fails the gate" (= 1 (gate-rc d3 "")))

# cell 3b: the same verdict marked STALE is accepted
(def d3b (stage (fresh-dir "stale-verdict-ok")))
(plant d3b "scope-model.qnt" "//   (likewise absorptionNever, presenceNeverFlips)"
       "//   (likewise absorptionNever, presenceNeverFlips)\n//   quint verify --invariant=pbS2 GREEN STALE - withdrawn by the fixture fix")
(check "stale-marked verdict passes" (= 0 (gate-rc d3b "")))

# cell 4: the shipped tree, unmodified, must close
(def d4 (stage (fresh-dir "shipped")))
(check "shipped tree closes the gate" (= 0 (gate-rc d4 "")))

# cell 5: the positive control (an injected stale citation) must fail
(def d5 (stage (fresh-dir "control")))
(check "positive control fires" (= 0 (gate-rc d5 "--control")))

(if (= failures 0)
  (print "RESULT: pass")
  (do (printf "RESULT: fail (%d)" failures) (os/exit 1)))
