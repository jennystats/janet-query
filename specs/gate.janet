# Spec gate - runs the typecheck, named runs and bounded verifies.
# Usage: janet specs/gate.janet [phase]   phase = baseline | final
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(def phase (or (first (script-args)) "final"))

(defn/typed cap {:args [:string] :ret :string} [cmd]
  "run a command through sh, return combined output"
  (string (sh-capture (string cmd " 2>&1"))))

(defn/typed say {:args [:string] :ret :nil} [s]
  (print s))

(def runs
  [["typecheck scope-model" "quint typecheck scope-model.qnt"]
   ["typecheck catalogue-record" "quint typecheck catalogue-record.qnt"]
   ["typecheck catalogue-shapes" "quint typecheck catalogue-shapes.qnt"]
   ["typecheck catalogue-partb" "quint typecheck catalogue-partb.qnt"]
   ["typecheck intersection" "quint typecheck intersection.qnt"]
   ["scope floor" "quint test --main=janetQueryScope --match='scope.*InMaterialisedModel' scope-model.qnt"]
   ["scope mutant" "quint test --main=janetQueryScope --match='MutantReadsANextState' scope-model.qnt"]
   ["catalogue pins" "quint test --main=janetQueryCatalogue --match='cmSamePathOwnersKeepDistinctKeys|cmSamePathPairRowRefusesTheSharedText' scope-model.qnt"]
   ["catalogue lane" "quint test --main=janetQueryCatalogue --match='cm.*' scope-model.qnt"]
   ["intersection" "quint test intersection.qnt"]])

(each [name cmd] runs
  (let [t0 (os/clock)
        out (cap cmd)
        dt (* 1000 (- (os/clock) t0))]
    (printf "\n===== %s (%.1fs)" name (/ dt 1000))
    (each line (string/split "\n" out)
      (when (not (empty? line))
        (say line)))))
