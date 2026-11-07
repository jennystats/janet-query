# Compare non-comment lines of two quint files.
(import jennystats/typed :prefix "")
(import jennystats/kit :prefix "")

(defn/typed strip {:args [:string] :ret :array} [p]
  (filter |(not (empty? $))
          (seq [l :in (string/split "\n" (slurp-string p))
                :when (not (string/has-prefix? "//" (string/trim l)))]
            (string/trim l))))

(defn/typed run {:args [] :ret :nil} []
  (def args (script-args))
  (def a (strip (args 0)))
  (def b (strip (args 1)))
  (printf "orig %d code lines, edit %d" (length a) (length b))
  (var i 0)
  (while (and (< i (length a)) (< i (length b)) (= (a i) (b i))) (++ i))
  (if (and (= i (length a)) (= i (length b)))
    (print "CODE IDENTICAL")
    (do
      (printf "first divergence at code line %d" i)
      (var k (- i 1))
      (while (< k (+ i 3))
        (when (and (>= k 0) (< k (length a)) (< k (length b)))
          (unless (= (a k) (b k))
            (printf "  L%d\n    orig: %s\n    edit: %s" k (a k) (b k))))
        (++ k)))))

(run)
