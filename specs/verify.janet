# Bounded verifies and typechecks recorded in the spec header.
# Usage: janet specs/verify.janet   (run from the specs/ directory)
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(defn/typed say {:args [:string] :ret :nil} [s] (print s))

(defn/typed run {:args [:string] :ret :nil} [cmd]
  (printf "\n===== %s" cmd)
  (each line (string/split "\n" (string (sh-capture (string cmd " 2>&1"))))
    (when (or (string/find "PASS" line) (string/find "FAIL" line)
              (string/find "rror" line) (string/find "Timeout" line)
              (string/find "[ok]" line) (string/find "[violation]" line))
      (say (string/trim line)))))

(def typechecks
  ["quint typecheck scope-model.qnt"
   "quint typecheck catalogue-record.qnt"
   "quint typecheck catalogue-shapes.qnt"
   "quint typecheck catalogue-partb.qnt"
   "quint typecheck intersection.qnt"])

(def absent ["ps2Neutrality" "absorptionNever" "presenceNeverFlips" "absentFieldUnions"])
(def present ["ps2Neutrality" "absorptionNever" "presenceNeverFlips"])

(each c typechecks (run c))
(each inv absent
  (run (string "quint verify --main=janetQueryCatalogue --init=initAbsent --step=step --max-steps=3 --invariant=" inv " scope-model.qnt")))
(each inv present
  (run (string "quint verify --main=janetQueryCatalogue --init=initPresent --step=step --max-steps=3 --invariant=" inv " scope-model.qnt")))
