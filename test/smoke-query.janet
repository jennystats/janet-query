# smoke-query - the jennystats/query core conformance smoke (ENGINE-FREE:
# no backend module import, no engine lib anywhere).
#
# Cell naming (<area>|<edge>): the malformed and denied shapes are forged
# values (ordinary janet data, no engine) - observed shapes are the
# regression cells.
(import jennystats/query :prefix "jq/")
(import jennystats/typed :prefix "")

(defn assert-eq [a b msg]
  (unless (deep= a b) (errorf "FAIL %s: %q != %q" msg a b)))

(defn catch-err [f]
  (var c nil)
  (try (f) ([e] (set c e)))
  c)

(defn assert-err [f want msg]
  (assert-eq (catch-err f) want msg))

(def shared-matrix
  {:from :shared :group :shared :select :shared :order :shared
   :limit :shared :distinct :shared :append :shared
   :from-parquet :shared :write-parquet :shared})

(defn- err-is? [e want]
  "Shape-agnostic class check: every key/value in want appears in e
 (an error carrying extra facts, such as :backends, still matches)."
  (and (struct? e) (struct? want)
       (all (fn [[k v]] (deep= (get e k) v)) (pairs want))))

(defn assert-errz [f want msg]
  (def got (catch-err f))
  (assert-eq (err-is? got want) true msg))

(defn reg-fake
  "Register a throwaway fake backend with the given matrix extra lanes;
  renderer/execute record their calls so denial-before-render is
  observable (property (c))."
  [nm &opt matrix-extra]
  (def calls @{:render 0 :exec 0})
  (jq/register-backend!
    @{:name nm
      :renderer (fn [tree] (put calls :render (inc (calls :render)))
                 @{:sql "FAKE" :tree tree :calls calls})
      :execute (fn [form] (put calls :exec (inc (calls :exec)))
                 @{:rows @[] :columns @[]})
      :catalog-spec @{}
      :matrix (merge shared-matrix (or matrix-extra {}))})
  calls)

# -- constructor shapes -------------------------------------------
(assert-eq (jq/from :t) {:node :from :src :t :alias nil} "from|base shape")
(assert-eq (jq/from :t :alias :e1)
           {:node :from :src :t :alias :e1} "from|alias shape")
(assert-eq (jq/get :col :e1) {:expr :get :col :col :alias :e1}
           "get|base shape")
(assert-eq (jq/lit 5) {:expr :lit :value 5} "lit|base shape")
(assert-eq (jq/count-distinct (jq/get :x))
           {:expr :agg :agg :count-distinct :arg {:expr :get :col :x :alias nil}}
           "count-distinct|base shape")
(assert-eq (jq/in (jq/get :a) [1 2])
           {:expr :call :op :in
            :args (tuple {:expr :get :col :a :alias nil}
                         {:expr :lit :value 1} {:expr :lit :value 2})}
           "expr-in|base wraps raw set values as literals")
(assert-eq (jq/order (jq/from :t) [:a :desc] :b)
           {:node :order
            :keys [{:col :a :dir :desc} {:col :b :dir :asc}]
            :input {:node :from :src :t :alias nil}}
           "order|base shape")

# -- forged trees ---------------------
(assert-err (fn [] (jq/expand-tree {:node :bogus}))
  {:error :malformed-tree :node {:node :bogus} :why :unknown-node}
  "malformed|unknown-node")
(assert-err (fn [] (jq/expand-tree [1 2 3]))
  {:error :malformed-tree :node [1 2 3] :why :node-not-struct}
  "malformed|not-struct")
(assert-err (fn [] (jq/expand-tree (jq/where (jq/from :t) 5)))
  {:error :malformed-tree :node 5 :why :where-pred}
  "malformed|where-pred-not-expr")
(assert-err (fn [] (jq/expand-tree (jq/order (jq/from :t) [[:a]])))
  {:error :malformed-tree :node {:key [[:a]]} :why :order-key-pair}
  "malformed|order-key-pair")
(assert-err (fn [] (jq/expand-tree (jq/limit (jq/from :t) "3")))
  {:error :malformed-tree :node {:node :limit :n "3" :form :head
                                 :input {:node :from :src :t :alias nil}}
           :why :limit-n-type}
  "malformed|limit-n-type")
(assert-err (fn [] (jq/expand-tree
                     (jq/select (jq/group (jq/from :t) [:a] (jq/lit 1)) :a)))
  {:error :malformed-tree
   :node {:node :group :keys [:a]
          :aggs [{:expr :lit :value 1}]
          :input {:node :from :src :t :alias nil}}
   :why :group-agg-not-aggregate}
  "malformed|group-agg-not-aggregate (names the group node)")
(assert-err (fn [] (jq/expand-tree
                     (jq/where (jq/from :t) (jq/eq (jq/get :x) (jq/lit 1)))))
  nil "malformed|valid-where-pred-passes (control)")
(assert-err (fn [] (jq/expand-tree (jq/from {:ptr 1})))
  {:error :malformed-tree
   :node {:node :from :src {:ptr 1} :alias nil} :why :handle-without-backend}
  "malformed|handle-without-backend")
(assert-err (fn [] (jq/expand-tree {:node :where
                                    :input {:node :from :src :t :alias nil}}))
  {:error :malformed-tree :why :where-pred}
  "malformed|missing-pred (nil pred named at the why)")

# -- the 4.1 validation lanes -------------------------------
(assert-err (fn [] (jq/register-backend!
                     @{:name :fake-reg1 :renderer 1 :execute 2
                       :catalog-spec @{} :matrix shared-matrix}))
  {:error :registration :kind :renderer-not-function :backend :fake-reg1}
  "registration|renderer-not-function")
(assert-err (fn [] (jq/register-backend!
                     @{:name :fake-reg2 :renderer (fn [t] t) :execute (fn [f] f)
                       :catalog-spec @{}
                       :matrix (merge shared-matrix {:bogus-op :native})}))
  {:error :registration :kind :malformed-matrix :operator :bogus-op
   :backend :fake-reg2}
  "registration|unknown-matrix-key")
(assert-err (fn [] (jq/register-backend!
                     @{:name :fake-reg2 :renderer (fn [t] t) :execute (fn [f] f)
                       :catalog-spec @{} :matrix {:from :shared :select :shared}}))
  {:error :registration :kind :shared-op-undeclared :operator :group
   :backend :fake-reg2}
  "registration|shared-op-undeclared (a well-formed matrix declares the shared set)")
(assert-err (fn [] (jq/register-backend!
                     @{:renderer (fn [t] t) :execute (fn [f] f)
                       :catalog-spec @{} :matrix shared-matrix}))
  {:error :registration :kind :missing-key :key :name :backend nil}
  "registration|missing-key")

# -- precedence, no default ever --------------------------------
(assert-err (fn [] (jq/render (jq/from :t)))
  {:error :backend-ambiguous} "selection|ambiguous (no default backend)")
(assert-err (fn [] (jq/render (jq/from :t) :backend :never-registered))
  {:error :unknown-backend :backend :never-registered}
  "selection|unknown-backend")
(def calls-sel (reg-fake :f-sel))
(assert-eq ((jq/render (jq/from :t) :backend :f-sel) :sql) "FAKE"
           "selection|explicit-backend renders")
(assert-eq (calls-sel :render) 1 "selection|renderer-called-once")

# provenance: a handle source commits a backend
(def calls-prov (reg-fake :f-prov))
(assert-eq ((jq/render (jq/from {:backend :f-prov})) :sql) "FAKE"
           "selection|provenance-infers-backend-no-explicit")
(assert-eq (calls-prov :render) 1 "selection|provenance-renders-once")

# -- explicit vs provenance disagree, never executes --
(reg-fake :f-conf)
(assert-err (fn [] (jq/render (jq/from {:backend :f-sel}) :backend :f-conf))
  {:error :backend-conflict :explicit :f-conf :inferred :f-sel}
  "selection|conflict-named-both")
(assert-err (fn [] (jq/execute (jq/from {:backend :f-sel}) :backend :f-conf))
  {:error :backend-conflict :explicit :f-conf :inferred :f-sel}
  "selection|conflict-never-executes")

# -- two handle backends refuse at composition --------
# a tree whose from-nodes carry handles from two distinct backends is a
# cross-engine query, out of scope by construction: refused where it is
# built, before selection, naming the second offending from-node and both
# backends. The refusal fires on the mixed-handle shape (duckdb handle + rayforce
# handle in one tree, which pre-fix selected neither and executed silently).
(def xb-a (jq/from {:backend :f-sel}))
(def xb-b (jq/from {:backend :f-conf}))
(assert-err (fn [] (jq/render (jq/where (jq/join xb-a xb-b :a :a)
                                        (jq/lt (jq/get :x) (jq/lit 1)))
                              :backend :f-sel))
  {:error :malformed-tree :node xb-b :why :cross-backend-handles
   :backends [:f-conf :f-sel]}
  "cross-backend|two-handles-raise-naming-both")
# same guard on the execute path (composition, not render-specific)
(assert-err (fn [] (jq/execute (jq/append xb-a xb-b) :backend :f-sel))
  {:error :malformed-tree :node xb-b :why :cross-backend-handles
   :backends [:f-conf :f-sel]}
  "cross-backend|refused-before-selection-on-execute")
# a handle plus a parquet from-node stays LEGAL (parquet carries no
# provenance), and so does a handle plus a catalog table name: neither
# raises the cross-backend class (the tree may still be denied for an
# unrelated reason, so these cells assert the guard's class is absent)
(defn- cross-backend-raised? [f]
  (= :cross-backend-handles (get (catch-err f) :why)))
(def mix-parquet (jq/join xb-a (jq/from-parquet "/tmp/x.parquet") :a :a))
(assert-eq (cross-backend-raised? (fn [] (jq/render mix-parquet :backend :f-join)))
           false "cross-backend|handle-plus-parquet-legal")
(reg-fake :f-join {:join :native :where :native})
(def mix-table (jq/join xb-a (jq/from :plain-table) :a :a))
(assert-eq (cross-backend-raised? (fn [] (jq/render mix-table :backend :f-join)))
           false "cross-backend|handle-plus-catalog-table-legal")
# TWO handles naming the SAME backend stay legal (one backend, one execution)
(def xb-a2 (jq/from {:backend :f-sel}))
(assert-eq ((jq/render (jq/append xb-a xb-a2) :backend :f-sel) :sql)
           "FAKE" "cross-backend|same-backend-handles-legal")

# -- the guard reads mutable-table trees too--
# collect-sources and the guard walk map-like values (dictionary? covers
# tables and structs), so a tree built from MUTABLE nodes carries
# provenance. Pre-fix a table tree walked with EMPTY provenance: it
# selected silently and defeated the guard entirely.
(def tb-a @{:node :from :src @{:backend :f-sel} :alias nil})
(def tb-b @{:node :from :src @{:backend :f-conf} :alias nil})
(assert-err (fn [] (jq/render (jq/append tb-a tb-b) :backend :f-sel))
  {:error :malformed-tree :node tb-b :why :cross-backend-handles
   :backends [:f-conf :f-sel]}
  "cross-backend|table-tree-two-handles-raise")
# a table tree with ONE handle backend is NOT cross-backend-refused (the
# guard is silent when provenance is single); it proceeds to selection and
# expansion rejects it as :node-not-struct - the node-carrier rule (structs
# only) stays the expansion boundary. The spoiler was
# that a table tree walked with EMPTY provenance (pre-fix), defeating BOTH
# the guard and the conflict rows entirely; provenance collection is now
# representation-agnostic.
(assert-eq (cross-backend-raised?
             (fn [] (jq/render (jq/append tb-a (jq/from :plain-table)) :backend :f-sel)))
           false "cross-backend|table-tree-one-handle-not-cross-refused")
(assert-err (fn [] (jq/render (jq/append tb-a (jq/from :plain-table)) :backend :f-sel))
  {:error :malformed-tree :node tb-a :why :node-not-struct}
  "cross-backend|table-tree-one-handle-expansion-boundary")

# -- extension nodes, facts named ------------------
(def calls-w (reg-fake :f-where))
(assert-err (fn [] (jq/render (jq/where (jq/from :t) (jq/lt (jq/get :x) (jq/lit 1)))
                              :backend :f-where))
  {:error :extension-denied :operator :where :backend :f-where}
  "denial|where-on-shared-only-backend")
(assert-eq (calls-w :render) 0 "denial|denial-before-render (property c)")
(assert-eq (calls-w :exec) 0 "denial|denial-before-execute (property c)")

(assert-err (fn [] (jq/render (jq/window (jq/from :t)) :backend :f-where))
  {:error :extension-denied :operator :window :backend :f-where}
  "denial|window-denied-by-every-v1-backend")
(assert-err (fn [] (jq/render (jq/pivot (jq/from :t)) :backend :f-where))
  {:error :extension-denied :operator :pivot :backend :f-where}
  "denial|pivot-denied-by-every-v1-backend")
(assert-err (fn [] (jq/render (jq/join (jq/from :t) (jq/from :u) :a :a)
                              :backend :f-where))
  {:error :extension-denied :operator :join :backend :f-where}
  "denial|join-denied-on-shared-only-backend")

# escape: matrix-declared AND tag-matched; off-tag = denial
(reg-fake :f-esc {:escape :native :where :native})
(assert-eq ((jq/render (jq/where (jq/from :t)
                                  (jq/and2 (jq/escape :f-esc "t.x > 1") (jq/lit true)))
                       :backend :f-esc) :sql)
           "FAKE" "escape|tag-matched-renders")
(assert-err (fn [] (jq/render (jq/where (jq/from :t)
                                         (jq/and2 (jq/escape :other "t.x > 1")
                                                  (jq/lit true)))
                              :backend :f-esc))
  {:error :extension-denied :operator :escape :backend :f-esc}
  "escape|off-tag-denied (non-portable by construction)")
(assert-err (fn [] (jq/render (jq/where (jq/from :t)
                                         (jq/and2 (jq/escape :f-where "x") (jq/lit true)))
                              :backend :f-where))
  {:error :extension-denied :operator :where :backend :f-where}
  "escape|undeclared-escape-lane: the where denial fires first (denial is
per-node-type; an escape atom inside a denied lane names that lane)")

# -- the matrix-declared expansion strategy ----------------
(reg-fake :f-cd {:count-distinct :expansion})
(def rewritten
  ((jq/render (jq/group (jq/from :t) [:a] (jq/count-distinct (jq/get :x)))
              :backend :f-cd) :tree))
(assert-eq rewritten
           {:node :group :keys [:a]
            :aggs [{:expr :agg :agg :count
                    :arg {:expr :get :col :x :alias nil}}]
            :input {:node :distinct
                    :input {:node :select :cols [:a :x]
                            :input {:node :from :src :t :alias nil}}}}
           "count-distinct|expansion two-graph composition")
(assert-err (fn [] (jq/render (jq/group (jq/from :t) [:a]
                                        (jq/count-distinct (jq/get :x))
                                        (jq/sum (jq/get :y)))
                              :backend :f-cd))
  {:error :malformed-tree
   :node {:node :group :keys [:a]
          :aggs [{:expr :agg :agg :count-distinct
                  :arg {:expr :get :col :x :alias nil}}
                 {:expr :agg :agg :sum :arg {:expr :get :col :y :alias nil}}]
          :input {:node :from :src :t :alias nil}}
   :why :mixed-count-distinct}
  "count-distinct|mixed-aggs v1 boundary")
# native lane: no rewrite
(reg-fake :f-cdn {:count-distinct :native})
(assert-eq ((jq/render (jq/group (jq/from :t) [:a] (jq/count-distinct (jq/get :x)))
                       :backend :f-cdn) :tree)
           {:node :group :keys [:a]
            :aggs [{:expr :agg :agg :count-distinct
                    :arg {:expr :get :col :x :alias nil}}]
            :input {:node :from :src :t :alias nil}}
           "count-distinct|native-no-rewrite")
# undeclared: denial
(assert-err (fn [] (jq/render (jq/group (jq/from :t) [:a]
                                        (jq/count-distinct (jq/get :x)))
                              :backend :f-where))
  {:error :extension-denied :operator :count-distinct :backend :f-where}
  "count-distinct|undeclared-denied")

# -- name checks when present, the engine decides when absent ----------
(def cat {:emp {:columns [:id :pay :dept]}})
(assert-err (fn [] (jq/render (jq/from :nope) :backend :f-sel :catalog cat))
  {:error :unknown-table :name :nope} "catalog|unknown-table")
(assert-err (fn [] (jq/render (jq/where (jq/from :emp) (jq/lt (jq/get :nope) (jq/lit 1)))
                              :backend :f-sel :catalog cat))
  {:error :unknown-column :name :nope} "catalog|unknown-column")
(assert-err (fn [] (jq/render (jq/append (jq/select (jq/from :emp) :id :pay)
                                         (jq/select (jq/from :emp) :id))
                              :backend :f-sel :catalog cat))
  {:error :malformed-tree
   :node {:node :append :sides
          [{:node :select :cols [:id :pay]
            :input {:node :from :src :emp :alias nil}}
           {:node :select :cols [:id]
            :input {:node :from :src :emp :alias nil}}]}
   :why :append-column-mismatch}
  "append|column-mismatch-names-append-node")
# absent catalog: same shapes render (the engine decides)
(assert-eq ((jq/render (jq/from :nope) :backend :f-sel) :sql) "FAKE"
           "catalog|absent-engine-decides")
# execute HONOURS :catalog too (the option parser once accepted the
# key then dropped it, so the expansion-time name check was skipped and
# the raw engine binder error surfaced instead)
(assert-err (fn [] (jq/execute (jq/from :nope) :backend :f-sel :catalog cat))
  {:error :unknown-table :name :nope} "catalog|execute-unknown-table")
(assert-err (fn [] (jq/execute (jq/where (jq/from :emp) (jq/lt (jq/get :nope) (jq/lit 1)))
                               :backend :f-join :catalog cat))
  {:error :unknown-column :name :nope} "catalog|execute-unknown-column")
# a catalog containing the referenced table executes unchanged
(assert-eq (jq/execute (jq/from :emp) :backend :f-sel :catalog cat)
           @{:rows @[] :columns @[]} "catalog|execute-catalog-hit-passes")
# absent catalog on execute: unchanged (the engine decides)
(assert-eq (jq/execute (jq/from :nope) :backend :f-sel)
           @{:rows @[] :columns @[]} "catalog|execute-absent-catalog")

# -- bare scope, tree-based validation, shadowing ----------------
(jq/defquery spent
  (from :emp)
  (where (lt (get :pay) (lit 3)))
  (select :id :pay))
(assert-err (fn [] (jq/execute spent :backend :f-sel))
  {:error :extension-denied :operator :where :backend :f-sel}
  "defquery|denied-on-shared-only-backend (where lane)")
(reg-fake :f-full {:where :native})
(assert-eq (jq/execute spent :backend :f-full)
           @{:rows @[] :columns @[]} "defquery|executes-on-where-backend")
(assert-eq (get spent :manifest)
           [:select :where :from]
           "defquery|manifest-attached")
# dynamic composition through prefixed constructors: same tree
(def spent-2
  (jq/select
    (jq/where (jq/from :emp) (jq/lt (jq/get :pay) (jq/lit 3)))
    :id :pay))
(assert-eq (get spent :tree) spent-2
           "defquery|same-tree-as-prefixed-composition")
# shadowing detection (compile-time string diagnostic, wrapped by the
# compiler - assert on the message)
(def sh1 (catch-err (fn [] (eval ~(jq/defquery bad
                                      (let [where 1] (from :t)))))))
(unless (and sh1 (string/find "defquery-shadowing: where" (string sh1)))
  (errorf "FAIL defquery|shadowing-detected: %q" sh1))
(def sh2 (catch-err (fn [] (eval ~(jq/defquery bad2
                                      (fn [select] (from :t)))))))
(unless (and sh2 (string/find "defquery-shadowing: select" (string sh2)))
  (errorf "FAIL defquery|param-shadowing-detected: %q" sh2))
# arbitrary user code keeps working inside the scope (expressions
# compose; the threading is -> - mid-chain lets live inside arguments)
(jq/defquery with-code
  (limit (from :t) (let [n (+ 1 2)] n)))
(assert-eq (get with-code :tree)
           {:node :limit :n 3 :form :head :input {:node :from :src :t :alias nil}}
           "defquery|user-code-composes")

# -- the option set is contract-stated ---------------------------
(assert-err (fn [] (jq/render (jq/from :t) :backend :f-sel :bogus 1))
  {:error :malformed-tree :node {:option :bogus} :why :unknown-option}
  "options|unknown-option-named-error")

# -- the coverage manifest is data ------------------------------
(assert-eq (type jq/coverage-manifest) :table "manifest|is-data (a table)")
(assert-eq (pairs jq/coverage-manifest) @[]
           "manifest|empty-until-a-backend-registers-rows")

# -- the ONE result shape ------------------------------------
(assert-eq (jq/wrap-result @[[1 2]] @[:a :b]) @{:rows @[[1 2]] :columns @[:a :b]}
           "result|wrapper-shape")
(assert-err (fn [] (jq/wrap-result 5 @[:a]))
  {:error :internal :kind :bad-rows} "result|bad-rows-named-error")

#==------------------------------------------------------------------------==#
# Regression cells: tree-pass and catalogue behaviours
#==------------------------------------------------------------------------==#

# -- cycle protection in the pre-selection walks ----------------
# A true mutable-table cycle (structs cannot self-reference) used to loop
# forever in collect-sources / guard-cross-backend before expansion could
# refuse it. Both walks carry an ancestor path now: a node equal to one of
# its own ancestors raises the contract class.
# The cells assert the error's FACTS, never a whole value carrying the
# cycle: janet's `=` recurses into containers, so comparing two values that
# contain the same cycle hangs the test itself.
(def cyc-self @{:node :select :cols @[:id]})
(put cyc-self :input cyc-self)
(def cyc-a @{:node :select :cols @[:id]})
(def cyc-b @{:node :limit :n 1 :form :head :input cyc-a})
(put cyc-a :input cyc-b)
(defn cyc-from [] (def f @{:node :from :src @{:backend :f-sel} :alias nil})
  (put f :input f) f)
(assert-errz (fn [] (jq/guard-cross-backend cyc-self))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|self-cycle-input raises cyclic-tree")
(assert-errz (fn [] (jq/collect-sources cyc-self))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|collect-sources self-cycle raises cyclic-tree")
(assert-errz (fn [] (jq/guard-cross-backend cyc-a))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|two-table-cycle raises at the revisited node")
(assert-errz (fn [] (jq/guard-cross-backend (cyc-from)))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|from-node-cycle raises cyclic-tree")
(assert-errz (fn [] (jq/render cyc-self :backend :f-sel))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|render path raises the contract class, not a hang")

# -- the guard sees from-parquet provenance too ----------------------
# collect-sources reads :backend from a from-parquet node's :src as well;
# the guard walked :from only, so a cross-engine tree mixing the two
# shapes slipped past the guard and executed with an explicit backend.
(def xb-pq (jq/from-parquet "/tmp/p.parquet" :src {:backend :f-conf}))
(assert-err (fn [] (jq/render (jq/append xb-a xb-pq) :backend :f-sel))
  {:error :malformed-tree :node xb-pq :why :cross-backend-handles
   :backends [:f-conf :f-sel]}
  "guard|parquet-provenance-mixed-with-handle raises")
(assert-errz (fn [] (jq/execute (jq/append xb-a (jq/from-parquet "/tmp/q.parquet"
                                                             :src {:backend :f-conf}))
                                :backend :f-sel))
  {:error :malformed-tree :why :cross-backend-handles}
  "guard|refused-before-execution-on-the-execute-path")
# a plain parquet node (no :src) stays neutral next to a handle
(assert-eq (cross-backend-raised?
             (fn [] (jq/render (jq/append xb-a (jq/from-parquet "/tmp/r.parquet"))
                               :backend :f-sel)))
           false "guard|handle-plus-plain-parquet-legal")

# -- ALL distinct backends, sorted -------------------
(reg-fake :f-third)
(def xb-c (jq/from {:backend :f-third}))
(assert-err (fn [] (jq/render (jq/append (jq/append xb-b xb-a) xb-c) :backend :f-sel))
  {:error :malformed-tree :node xb-c :why :cross-backend-handles
   :backends [:f-conf :f-sel :f-third]}
  "a18|three-backends-names-all-three-sorted")

# -- unregistered handle provenance is :unknown-backend ---
# The handle is user-authored data; selection classified it as a module
# defect (:internal / :shared-op-missing) because the unregistered backend
# flowed through selection into the matrix recheck.
(def h-nope (jq/from {:backend :f-nope :handle :h1}))
(assert-errz (fn [] (jq/render h-nope :backend :f-sel))
  {:error :unknown-backend :backend :f-nope}
  "selection|unregistered-handle-provenance-unknown-backend")
(assert-errz (fn [] (jq/execute (jq/select h-nope :x)))
  {:error :unknown-backend :backend :f-nope}
  "selection|no-explicit-backend-same-class")
(assert-errz (fn [] (jq/execute (jq/select (jq/from :t) :x)))
  {:error :backend-ambiguous}
  "selection|no-provenance-still-backend-ambiguous")

# -- one disagreement, one class ---------------------------
# A handle source with NO usable :backend is the ambiguity, and the class
# must not depend on call options (:backend-ambiguous when
# provenance is empty or multi-valued, :handle-without-backend only for a
# tree the public expand-tree entry refuses on its own). The explicit-backend
# shape is therefore :backend-ambiguous too - the two shapes below are
# byte-identical trees and must land on one class.
(assert-errz (fn [] (jq/render (jq/from {:handle :h1}) :backend :f-sel))
  {:error :backend-ambiguous}
  "class|no-backend-key-explicit is backend-ambiguous, not a class flip")
(assert-eq (catch-err (fn [] (jq/render (jq/from {:handle :h1}) :backend :f-sel)))
           (catch-err (fn [] (jq/render (jq/from {:handle :h1}))))
           "class|same-shape-same-class-no-explicit")
(assert-errz (fn [] (jq/render (jq/from {:backend "f-sel"}) :backend :f-sel))
  {:error :unknown-backend :backend "f-sel"}
  "class|string-backend-unknown-backend-not-a-conflict")
(assert-errz (fn [] (jq/render (jq/from {:backend :f-conf}) :backend :f-sel))
  {:error :backend-conflict :explicit :f-sel :inferred :f-conf}
  "class|registered-disagreement-stays-backend-conflict")

# -- nested :query expands; :query in an input slot is malformed ----
(assert-errz (fn [] (jq/render (jq/limit (jq/window (jq/from :t)) 3) :backend :f-where))
  {:error :extension-denied :operator :window :backend :f-where}
  "query|window-denial-names-window-not-query")
(def nq-tree (jq/where (jq/from :t) (jq/lt (jq/get :x) (jq/lit 1))))
(def nq-wrapper {:node :query :name "w" :tree nq-tree})
# a wrapper is transparent at the TOP level (the prepare entry unwraps it)
(assert-eq (get (jq/expand-tree nq-wrapper) :node-types)
           [:where :from]
           "query|top-level-wrapper-is-transparent")
# ... and malformed in an operand slot, whatever the operand (fix 10)
(assert-errz (fn [] (jq/expand-tree {:node :limit :n 3 :form :head :input nq-wrapper}))
  {:error :malformed-tree :why :query-not-input}
  "query|wrapper-in-input-slot-raises-query-not-input")
(assert-errz (fn [] (jq/render {:node :select :cols @[:x] :input nq-wrapper}
                               :backend :f-sel))
  {:error :malformed-tree :why :query-not-input}
  "query|query-in-input-slot-raises-query-not-input")

# -- alias-qualified columns are catalog-checked ---------------------
(def alias-cat (table :t @{:columns @[:a :b]}
                     :u @{:columns @[:a :b]}))
(put alias-cat "/tmp/ap.parquet" @{:columns @[:a :b]})
(def aliased (jq/from :t :alias :e1))
(defn get-alias [c a] {:expr :get :col c :alias a})
(assert-errz (fn [] (jq/expand-tree (jq/select aliased (get-alias :zzz :e1)) alias-cat))
  {:error :unknown-column :name :zzz}
  "catalog|alias-qualified-unknown-column-raises")
(assert-eq (get (jq/expand-tree (jq/select aliased (get-alias :a :e1)) alias-cat)
                :columns)
           [:a] "catalog|alias-qualified-known-column-passes")
(assert-errz (fn [] (jq/expand-tree (jq/select aliased (get-alias :b :e9)) alias-cat))
  {:error :unknown-column :name :e9}
  "catalog|unknown-alias-raises-naming-the-alias")
# from-parquet resolves through the source KEY (the path), never the file
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/from-parquet "/tmp/ap.parquet") :zzz)
                                    alias-cat))
  {:error :unknown-column :name :zzz}
  "catalog|parquet-source-key-column-checked")
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/from :nonesuch) :a) alias-cat))
  {:error :unknown-table :name :nonesuch}
  "catalog|unknown-table-names-the-table")
# an unnamed parquet source leaves the engine as the only validator:
# the name CHECK is skipped (no error), the projection is still known
(assert-eq (get (jq/expand-tree (jq/select (jq/from-parquet "/nomatch.parquet") :a)
                                alias-cat) :columns)
           [:a] "catalog|unnamed-parquet-source-skips-column-check")

# -- the core seam wraps and validates the engine result -------------
(defn reg-bare [nm ret]
  (jq/register-backend!
    @{:name nm
      :renderer (fn [tree] @{:sql "BARE"})
      :execute (fn [form] ret)
      :catalog-spec @{}
      :matrix (merge shared-matrix {:where :native})}))
(reg-bare :f-bare "BARE STRING NOT A WRAPPER")
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :f-bare))
  {:error :internal :kind :bad-result-shape}
  "seam|non-wrapper-engine-result-rejected")
(reg-bare :f-baretbl @{:columns @[:a] :rows @[@[1] @[2]]})
(assert-eq (jq/execute (jq/from :t) :backend :f-baretbl)
           @{:rows @[(tuple 1) (tuple 2)] :columns @[:a]}
           "seam|struct-table-result-shaped-by-the-seam")
(reg-bare :f-bareplain @[[1] [2]])
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :f-bareplain))
  {:error :internal :kind :bad-result-shape}
  "seam|bare-table-no-columns-rejected")
(reg-bare :f-tuplewrap [{:rows [[1]] :columns [:a]}])
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :f-tuplewrap))
  {:error :internal :kind :bad-result-shape}
  "seam|wrapper-inside-a-sequence-rejected")

# -- mutable slots are frozen at the tree pass -------------------
(def toctou-cols @[:id])
(def toctou-q {:node :select :cols toctou-cols
               :input {:node :from :src "albums" :alias nil}})
(def toctou-1 (jq/expand-tree toctou-q))
(array/push toctou-cols :sneaky)
(assert-eq (get (get toctou-1 :tree) :cols) [:id]
           "freeze|expanded-tree-holds-the-frozen-cols")
(def toctou-2 (jq/expand-tree toctou-q))
(assert-eq (get (get toctou-2 :tree) :cols) [:id :sneaky]
           "freeze|a-later-expansion-sees-the-mutated-array")
(assert-eq toctou-cols @[:id :sneaky] "freeze|user-array-left-untouched")

# -- nested array projections are malformed, never quoted -------------
(defn no-pointer? [e]
  (not (peg/match ~"0x[%x]+" (string/format "%q" e))))
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/from :t) [(jq/get :x)])))
  {:error :malformed-tree :why :select-col-type}
  "select|array-arg-is-a-nested-projection")
(assert-errz (fn [] (jq/render (jq/select (jq/from :t) @[(jq/get :x)]) :backend :f-sel))
  {:error :malformed-tree :why :select-col-type}
  "select|mutable-array-arg-is-a-nested-projection")
(assert-eq (no-pointer? (catch-err (fn [] (jq/render (jq/where (jq/from :t) (jq/get :x))
                                                    :backend :f-where))))
           true "select|no-address-in-the-surfaced-error")
(assert-eq (get (jq/expand-tree (jq/select (jq/from :t) :a "b")) :columns)
           [:a :b] "select|keyword-and-string-cols-still-valid (both spellings are one name form)")

# -- rows are tuples - the docstring says so ------------
(def f-m1-7-row (first (get (jq/execute (jq/from :t) :backend :f-baretbl) :rows)))
(assert-eq (tuple? f-m1-7-row) true "rows|row-is-a-tuple")

# -- parquet sources gate through the caller catalog ------------
# The file's column names live in the caller's catalog under the parquet
# source KEY (the path); the engine remains the default validator when the
# key is absent (see smoke-query-duckdb for the engine-backed cell).
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/from-parquet "/tmp/pp.parquet") :x)
                                    @{"__lkey" @{:columns @[:a]}
                                      "/tmp/pp.parquet" @{:columns @[:a]}}))
  {:error :unknown-column :name :x}
  "parquet|unknown-column-checked-against-the-source-key")
# the same tree with the key ABSENT leaves the check to the engine
(assert-eq (get (jq/expand-tree (jq/select (jq/from-parquet "/tmp/pp.parquet") :x)
                                @{"__lkey" @{:columns @[:a]}}) :columns)
           [:x] "parquet|absent-key-defers-to-the-engine")

#==------------------------------------------------------------------------==#
# Interaction regressions: every
# cell below is an INTERACTION lane (catalog x join, catalog x mixed source
# set, cycle x struct layout, freeze x non-expansion path, shared-subtree
# walk x depth), not the primary lane the 22 tiers already covered.
#==------------------------------------------------------------------------==#

# -- join key sentinels never reach the name check ---
# tree-columns emits [nil "__lkey" k] / [nil "__rkey" k] for join keys; the
# catalog check took the alias branch and named the internal sentinel. A
# catalog-checked join (both arms' C18a/C18c) raises nothing now.
(reg-fake :f-catj {:join :native :where :native})
(def cat-g {:t {:columns [:x :y :g]} :u {:columns [:x :z]}})
(assert-eq (get (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) :x :x) cat-g)
                :node-types)
           [:join :from] "catalog|join-over-catalogued-tables-raises-nothing")
(assert-eq ((jq/render (jq/join (jq/from :t) (jq/from :u) :x :x)
                       :backend :f-catj :catalog cat-g) :sql)
           "FAKE" "catalog|join-catalog-renders (C18a)")
(assert-eq (string/find "__" (string/format "%q"
                                             (catch-err (fn [] (jq/render (jq/join (jq/from :t) (jq/from :u) :x :x)
                                                                         :backend :f-catj :catalog cat-g)))))
           nil "catalog|no-internal-sentinel-in-the-surfaced-error")
# a real unknown column in a join-facing projection is still named (the
# lane-local exemption must not widen the check)
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/join (jq/from :t) (jq/from :u) :x :x)
                                               :nope) cat-g))
  {:error :unknown-column :name :nope}
  "catalog|join-real-unknown-column-still-raises")
# a join whose key lane is an uncatalogued parquet source invents nothing
(assert-eq (get (jq/expand-tree
                  (jq/join (jq/from :t) (jq/from-parquet "/tmp/jc.parquet") :x :x)
                  cat-g) :node-types)
           [:join :from :from-parquet]
           "catalog|join-uncatalogued-parquet-side-no-sentinel-error")

# -- the catalog check is per SOURCE, both ways ------
# catalogued -> uncatalogued (M2 C34): a column of the UNNAMED parquet
# source is the engine's to validate, never the catalog's to refuse
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/append (jq/from :t :alias :e1)
                                        (jq/from-parquet "/tmp/mx.parquet" :alias :pp))
                             {:expr :get :col :pqonly :alias :pp})
                  cat-g) :columns)
           [:pqonly] "catalog|mixed-tree-unnamed-parquet-deferred (C34)")
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/append (jq/from :t) (jq/from-parquet "/tmp/mx.parquet"))
                             :pqonly)
                  cat-g) :columns)
           [:pqonly] "catalog|mixed-tree-unqualified-unnamed-parquet-deferred (C34b)")
# uncatalogued -> catalogued: a column named on ONE source's
# alias is checked against THAT source's entry, never the tree's union
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/join (jq/from :t :alias :e1)
                                                     (jq/from :u :alias :e2) :x :x)
                                               {:expr :get :col :y :alias :e2}) cat-g))
  {:error :unknown-column :name :y}
  "catalog|alias-qualified-column-scoped-to-its-source")
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/join (jq/from :t :alias :e1) (jq/from :u :alias :e2) :x :x)
                             {:expr :get :col :z :alias :e2}) cat-g) :columns)
           [:z] "catalog|alias-qualified-known-column-still-passes")
# an unqualified reference over two catalogued sources is checked against
# each of them: :z exists only on :u, not on :t. AMENDED (the merged-row
# model): above a join the row carries BOTH
# arms, so this is no longer a refusal - matching SQL-engine semantics,
# where a select over a join sees every column of the joined row. The
# recorded refusal was the over-strictness class.
(assert-eq (get (jq/expand-tree (jq/select (jq/join (jq/from :t) (jq/from :u) :x :x)
                                          :z) cat-g) :columns)
           [:z]
           "catalog|multi-source-unqualified-column-scoped-to-its-source")
# a single catalogued source keeps the strict check (control)
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/from :t) :zz) cat-g))
  {:error :unknown-column :name :zz}
  "catalog|single-source-missing-column-still-raises")

# -- cycle identity is layout-stable, not content equality --------
# A node reached only through a slot its ancestor does not declare equal-
# content (the `:pad` keys differ) escapes content equality entirely; the
# identity walk still refuses it with the contract class.
(def cyc-inner (table/to-struct (merge {:node :select :cols @[:a]}
                                       {:input @{:node :from :src :t :alias nil}})))
(def cyc-lay (table/to-struct (merge {:node :limit :n 1 :form :head :input cyc-inner}
                                    {:pad 1})))
(put (get cyc-inner :input) :input cyc-lay)
(assert-eq (= (get cyc-lay :input) cyc-lay) false
           "cycle|precondition: the revisit does not compare equal to itself")
(assert-errz (fn [] (jq/guard-cross-backend cyc-lay))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|layout-variant-cycle-raises-cyclic-tree (M1 p37)")
(assert-errz (fn [] (jq/collect-sources cyc-lay))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|layout-variant-cycle-in-collect-sources")
(assert-errz (fn [] (jq/render cyc-lay :backend :f-sel))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|layout-variant-cycle-render-class (never :node-not-struct)")
# equal-content SIBLINGS stay legal (the content-equality path check got
# these right; identity keeps them right)
(assert-eq ((jq/render (jq/append (jq/from :t) (jq/from :t)) :backend :f-sel) :sql)
           "FAKE" "cycle|equal-content-siblings-still-legal")
# Same content, REVERSED declaration order. The claim was that a struct rebuilt with the same fields in
# another declaration order keys apart and escapes cycle detection. Probed
# and NOT reproduced: janet's struct hash and `=` both treat
# declaration order as irrelevant, so the old (hash ;(keys x)) key never
# separated content-equal structs (2000 reordered pairs, zero divergences).
# The cells below are the finding's own scenario as permanent regressions.
(def ord-arr @[:a])
(assert-eq (= (struct :node :select :cols ord-arr)
              (struct :cols ord-arr :node :select)) true
           "cycle|reordered-rebuild-compares-equal-to-content")
# an ancestor reached again through a REORDERED rebuild of itself raises the
# contract class in the walks that carry the cycle path
(def ord-cyc (struct :node :select :cols ord-arr :input nil))
(def ord-up @{:node :limit :n 1 :form :head :input ord-cyc})
(def ord-back (struct :cols ord-arr :node :select :input ord-up))
(put ord-up :input ord-back)
(assert-errz (fn [] (jq/collect-sources ord-up))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|reordered-rebuild-cycle-in-collect-sources")
(assert-errz (fn [] (jq/guard-cross-backend ord-up))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|reordered-rebuild-cycle-in-guard")
# the reference-identity arm: a MUTABLE REBUILD of a table node (same
# content, different object) is caught by content, a cycle through the SAME
# table object by identity - both land on the contract class
(def ord-t @{:node :select :cols @[:a] :input nil})
(def ord-tup @{:node :limit :n 1 :form :head :input ord-t})
(put ord-t :input ord-tup)
(assert-errz (fn [] (jq/collect-sources ord-tup))
  {:error :malformed-tree :why :cyclic-tree}
  "cycle|table-cycle-in-collect-sources")

# -- freeze holds on the NON-expansion prepare path --------------
# prepare rebound tree* to the caller's unfrozen tree when count-distinct
# expansion did not apply, so a render's :tree (and the next execute) saw
# the caller's later mutation.
(def rex-cols @[:id])
(def rex-q {:node :select :cols rex-cols :input {:node :from :src :t :alias nil}})
(def rex-r1 (jq/render rex-q :backend :f-sel))
(assert-eq (get (get rex-r1 :tree) :cols) [:id]
           "freeze|render-tree-is-frozen-cols (C12r)")
(array/push rex-cols :hacked)
(assert-eq (get (get rex-r1 :tree) :cols) [:id]
           "freeze|render-output-stable-after-caller-mutation (C12r)")
(assert-eq (get (get (jq/render rex-q :backend :f-sel) :tree) :cols) [:id :hacked]
           "freeze|a-later-render-sees-the-caller-owned-array")
(assert-eq (get (get (jq/prepare rex-q :f-sel nil) :tree) :cols) [:id :hacked]
           "freeze|prepare-returns-the-frozen-tree (non-expansion path)")
# C30: a recording backend sees the same frozen slots on both executes
# (the fake renderer records the tree it was handed; the SECOND execute
# must see the same slots it saw first - rex-q itself is re-wrapped so the
# renderer's tree is the prepare output, not the caller's array)
(def c30-cols @[:a :b])
(def c30-q {:node :select :cols c30-cols :input {:node :from :src :t :alias nil}})
(def c30-trees @[])
(jq/register-backend!
  @{:name :f-c30
    :renderer (fn [tree] (array/push c30-trees tree) @{:sql "C30" :tree tree})
    :execute (fn [form] @{:rows @[] :columns @[]})
    :catalog-spec @{}
    :matrix shared-matrix})
(jq/execute c30-q :backend :f-c30)
(array/push c30-cols :mutated)
(jq/execute c30-q :backend :f-c30)
(assert-eq (get (get (jq/execute c30-q :backend :f-c30) :rows) 0) nil
           "freeze|c30-recording-backend-executes")
# the first plan's tree is frozen at render time and cannot be changed by
# the caller afterwards (contract 1); the SECOND execute re-plans from the
# caller's now-mutated tree, which is the documented re-plan behaviour
(assert-eq (get (c30-trees 0) :cols) [:a :b]
           "freeze|first-render-tree-frozen-at-render-time (C30)")
(assert-eq (get (c30-trees 1) :cols) [:a :b :mutated]
           "freeze|second-render-re-plans-from-the-caller-tree (C30)")
# C23 control: expand-tree froze all along
(assert-eq (tuple? (get (get (jq/expand-tree rex-q) :tree) :cols)) true
           "freeze|expand-tree-holds-frozen-cols (C23 control)")

# -- shared-subtree walks are linear in node count ----------------
# A diamond (each level holds the SAME child on both :sides) is walked 2^d
# times by the pre-selection walks and the tree pass: depth 16 measured
# ~2 s per walk pre-fix. A subtree is now walked once per identity.
(defn diamond-tree [depth]
  (var cur {:node :from :src :t :alias nil})
  (for i 0 depth
    (def side {:node :select :cols @[:a] :input cur})
    (set cur {:node :append :sides (tuple side side)}))
  cur)
(defn join-diamond-tree [depth]
  (var cur {:node :from :src :t :alias nil})
  (for i 0 depth
    (set cur {:node :join :type :inner
              :left {:node :select :cols @[:a] :input cur}
              :right {:node :select :cols @[:a] :input cur}
              :lkeys [:a] :rkeys [:a]}))
  cur)
(defn under-budget? [ms f]
  (def t0 (os/clock))
  (f)
  (< (* 1000 (- (os/clock) t0)) ms))
(assert-eq (under-budget? 2000 (fn [] (jq/render (diamond-tree 12) :backend :f-sel)))
           true "walk|diamond-depth-12-renders-under-2s")
(each [nm f] [[:collect-sources (fn [] (jq/collect-sources (diamond-tree 16)))]
              [:guard (fn [] (jq/guard-cross-backend (diamond-tree 16)))]
              [:handle-without (fn [] (jq/handle-without-backend? (diamond-tree 16)))]
              [:tree-columns (fn [] (jq/tree-columns (diamond-tree 16)))]
              [:expand (fn [] (jq/expand-tree (diamond-tree 16)))]
              [:join-diamond-14 (fn [] (jq/expand-tree (join-diamond-tree 14)))]]
  (assert-eq (under-budget? 500 f) true
             (string "walk|" nm "-linear-in-node-count")))
# the shared subtree is still validated once, and once only: a defect inside
# a diamond child is still named (memoisation must not skip the child)
(assert-errz (fn [] (jq/expand-tree
                      {:node :append
                       :sides (tuple {:node :bogus}
                                     {:node :bogus})}))
  {:error :malformed-tree :why :unknown-node}
  "walk|diamond-child-still-validated")

#==------------------------------------------------------------------------==#
# Interaction-lane regressions.
#==------------------------------------------------------------------------==#

# -- the core seam refuses scalar rows with the contract grammar --
# A backend returning {:rows <scalars> :columns ...} used to escape the seam
# with janet's raw "expected array or tuple, got 1" (raised inside
# wrap-result's row conversion), outside the error grammar entirely.
(reg-bare :r3-scalar @{:rows @[1 2] :columns @[:x]})
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :r3-scalar))
  {:error :internal :kind :bad-result-shape :backend :r3-scalar}
  "seam|scalar-rows-refused-with-the-contract-class")
# the mixed lane: one scalar row among valid ones is refused, never normalised
(reg-bare :r3-mixed @{:rows @[(tuple 1) 2] :columns @[:x]})
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :r3-mixed))
  {:error :internal :kind :bad-result-shape}
  "seam|one-scalar-row-among-valid-rows-refused")
# a sequence-of-structs row lane is the same class (a row is positional)
(reg-bare :r3-structrow @{:rows @[@{:x 1}] :columns @[:x]})
(assert-errz (fn [] (jq/execute (jq/from :t) :backend :r3-structrow))
  {:error :internal :kind :bad-result-shape}
  "seam|struct-row-refused")
# control: the valid tuple row lane is untouched
(reg-bare :r3-ok @{:rows @[(tuple 1) (tuple 2)] :columns @[:x]})
(assert-eq (get (jq/execute (jq/from :t) :backend :r3-ok) :rows)
           @[(tuple 1) (tuple 2)]
           "seam|tuple-rows-pass-unchanged")

# -- catalog check sees the tree's own computed output columns ---
# (ruling 2A: computed-columns-aware). A group's own aggregate output name
# (agg_col, the module's deterministic naming, also what :columns reports)
# is a legitimate projection reference above it, while every stored-column
# reference keeps the per-source strictness.
(def r3-emp (table :cat_emp @{:columns @[:emp :dept :pay]}
                   :t @{:columns @[:a :b]}))
(defn r3-agg [op c] {:expr :agg :agg op :arg {:expr :get :col c :alias nil}})
(def r3-g (jq/group (jq/from :cat_emp) [:dept] (r3-agg :sum :pay)))
(assert-eq (get (jq/expand-tree r3-g r3-emp) :columns) [:dept 'sum_pay]
           "catalog|group-reports-its-own-output-columns (L2-a)")
(assert-eq (get (jq/expand-tree (jq/select r3-g :sum_pay) r3-emp) :columns)
           [:sum_pay]
           "catalog|computed-column-projects-through-a-catalog (L2-b)")
(assert-eq (get (jq/expand-tree (jq/select (jq/group (jq/from :cat_emp) [:dept] (r3-agg :avg :pay))
                                                 :avg_pay) r3-emp) :columns)
           [:avg_pay]
           "catalog|second-aggregate-output-name-also-known")
# the computed name passes while a stored reference keeps its own strictness
(assert-errz (fn [] (jq/expand-tree (jq/select r3-g :bogus) r3-emp))
  {:error :unknown-column :name :bogus}
  "catalog|computed-lane-does-not-widen-the-stored-check")
# a computed name does not leak ACROSS sources
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/join (jq/from :cat_emp) (jq/from :other) :dept :dept)
                                 :sum_pay)
                      (table :cat_emp @{:columns @[:emp :dept :pay]}
                             :other @{:columns @[:dept :z]})))
  {:error :unknown-column :name :sum_pay}
  "catalog|computed-name-scoped-to-the-subtree-that-computes-it")

# -- select above a group ---------------------------
# A select above a group refusing the group's OWN
# key was once reported; it does not reproduce:
# the group's key and its aggregate both serve, and only a column the group
# genuinely dropped refuses. These cells record the evaluation so the
# disposition rests on the asserted behaviour,
(assert-eq (get (jq/expand-tree (jq/select r3-g :dept) r3-emp) :columns)
           [:dept] "catalog|select-above-group-serves-the-group-key")
(assert-eq (get (jq/expand-tree (jq/select r3-g :sum_pay) r3-emp) :columns)
           [:sum_pay] "catalog|select-above-group-serves-the-aggregate")
(assert-errz (fn [] (jq/expand-tree (jq/select r3-g :pay) r3-emp))
  {:error :unknown-column :name :pay}
  "catalog|select-above-group-refuses-a-dropped-column")
# an unqualified stored ref every catalogued candidate names still passes
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/append (jq/from :t) (jq/from :u)) :x)
                  (table :t @{:columns @[:x :y]} :u @{:columns @[:x :z]})) :columns)
           [:x] "catalog|unqualified-ref-named-by-every-candidate-passes")
# the M2 mixed-source probe: a column named by only ONE
# of two catalogued sources is refused under the every-candidate reading -
# the chosen semantics, recorded so a change of reading fails a cell
# The join-union rule binds an unqualified reference to the sources beneath the
# referencing node and judge a selector above a merged row against the
# UNION. An append's row is its sides' position-aligned union, so `:p`,
# named by the parquet side alone, is IN SCOPE here and the every-candidate
# reading no longer decides this shape. The r9 fixture also appended a
# 2-column table to a 1-column parquet arm, which A17.1 refuses as a count
# mismatch before any column lane. Equal-width sources plus the live
# reading: both names pass, and the every-candidate reading is recorded where
# it still governs - a reference on a SOURCE, not on a merged row.
(def r3-mixed-cat (table :t @{:columns @[:a :b]} "/tmp/r3f.parquet" @{:columns @[:p :q]}))
(each r3-c [:p :a]
  (assert-eq (get (jq/expand-tree
                    (jq/select (jq/append (jq/from :t)
                                          (jq/from-parquet "/tmp/r3f.parquet")) r3-c)
                    r3-mixed-cat) :columns)
    [r3-c]
    (string "catalog|append-selector-reads-its-merged-row")))
# The arity lane is its own cell - a catalogued parquet arm of a
# different width refuses the append as malformed, naming the node
(assert-errz (fn [] (jq/expand-tree
                      (jq/append (jq/from :t)
                                 (jq/from-parquet "/tmp/r3f.parquet"))
                      (table :t @{:columns @[:a :b]} "/tmp/r3f.parquet" @{:columns @[:p]})))
  {:error :malformed-tree :why :append-column-mismatch}
  "catalog|append-width-mismatch-refuses-before-column-lane")

# -- the count-distinct rewrite memoises by identity --------------
# A shared diamond (each level holds the SAME child twice) used to make the
# rewrite 2^d nodes: depth 14 measured 1.6 s end to end. A shared child is
# now rewritten once per identity, like every other walk.
(defn cd-diamond [depth]
  (var cur {:node :group :keys [:k] :aggs [(r3-agg :count-distinct :c)]
            :input {:node :from :src :t :alias nil}})
  (for i 0 depth
    (def side {:node :select :cols @[:a] :input cur})
    (set cur {:node :append :sides (tuple side side)}))
  cur)
(assert-eq (under-budget? 2000 (fn [] (jq/expand-count-distinct (cd-diamond 12))))
           true "walk|count-distinct-diamond-12-under-2s")
# the memoised rewrite stays CORRECT on the shared lane: one rewrite, and it
# is the composition (count over a distinct projection)
(defn count-groups [t]
  (if (not (struct? t)) 0
    (+ (if (= :group (get t :node)) 1 0)
       (count-groups (get t :input))
       (if (get t :sides) (reduce + 0 (map count-groups (get t :sides))) 0))))
(defn first-group [t]
  (cond
    (not (struct? t)) nil
    (= :group (get t :node)) t
    (first-group (get t :input)) (first-group (get t :input))
    (and (get t :sides) (some first-group (get t :sides)))
    (first-group (some first-group (get t :sides)))
    (first-group (get t :left)) (first-group (get t :left))
    (first-group (get t :right)) (first-group (get t :right))
    nil))
(def r3-cd-out (jq/expand-count-distinct (cd-diamond 3)))
(def r3-cd-g (first-group r3-cd-out))
# correctness: a shared diamond keeps one distinct structure per level (the
# memo changes COST, never shape - the walk is guaranteed for the whole tree)
(assert-eq (count-groups r3-cd-out) 8
           "walk|shared-diamond-rewrites-every-level-in-place")
(assert-eq [(get (first (get r3-cd-g :aggs)) :agg)
            (get (first (get r3-cd-g :aggs)) :arg)
            (get (get (get r3-cd-g :input) :input) :node)]
           [:count {:expr :get :col :c :alias nil} :select]
           "walk|rewrite-is-count-over-distinct-projection")
# interaction: the rewritten diamond passes the tree pass unchanged
(assert-eq (get (jq/expand-tree r3-cd-out) :node-types)
           [:append :select :group :distinct :from]
           "walk|rewritten-diamond-passes-the-tree-pass")
# structural duplicates (NOT aliases) are each rewritten - memo keys by
# identity, never by content
(def r3-cd-dup (jq/expand-count-distinct
                 (let [g (cd-diamond 0)]
                   {:node :append
                    :sides (tuple {:node :select :cols @[:q] :input g}
                                  {:node :select :cols @[:q] :input g})})))
(assert-eq (count-groups r3-cd-dup) 2
           "walk|distinct-object-siblings-each-rewritten")

# -- from-parquet handle parity (ruling 3A) ------------------------
# A from-parquet :src carrying a :backend is provenance exactly as a from
# node's is; one WITHOUT a :backend is the same class as a from node's.
(reg-fake :r3-pq {})
(assert-errz (fn [] (jq/execute (jq/from-parquet "/tmp/r3.parquet" :src {:handle "h"})
                                :backend :r3-pq))
  {:error :backend-ambiguous}
  "parquet|handle-without-backend-is-backend-ambiguous")
(assert-errz (fn [] (jq/execute (jq/from-parquet "/tmp/r3.parquet" :src {:handle "h"})))
  {:error :backend-ambiguous}
  "parquet|handle-without-backend-no-explicit-backend-same-class")
(assert-errz (fn [] (jq/expand-tree (jq/from-parquet "/tmp/r3.parquet" :src {:handle "h"})))
  {:error :malformed-tree :why :handle-without-backend}
  "parquet|public-expand-tree-refuses-the-shape (the :from class)")
# with-backend variant: provenance selects with no explicit backend; a
# string :backend is user-authored data, not provenance
(assert-eq (get (jq/execute (jq/from-parquet "/tmp/r3.parquet"
                                              :src {:handle "h" :backend :r3-pq})) :columns)
           @[] "parquet|handle-backend-selects-with-no-explicit (C2 pair)")
(assert-errz (fn [] (jq/execute (jq/from-parquet "/tmp/r3.parquet"
                                                  :src {:handle "h" :backend "s1"})))
  {:error :unknown-backend :backend "s1"}
  "parquet|string-backend-is-the-unknown-backend-class")
# the guard sees parquet handles exactly as it sees from handles
(assert-errz (fn [] (jq/execute (jq/append
                                  (jq/from-parquet "/tmp/a.parquet"
                                                   :src {:handle "h" :backend :r3-pq})
                                  (jq/from-parquet "/tmp/b.parquet"
                                                   :src {:handle "h" :backend :f-sel}))
                                :backend :r3-pq))
  {:error :malformed-tree :why :cross-backend-handles}
  "parquet|cross-backend-guard-sees-parquet-handles")
# a parquet node with NO :src stays neutral
(assert-eq (get (jq/execute (jq/from-parquet "/tmp/r3.parquet") :backend :r3-pq) :columns)
           @[] "parquet|no-src-stays-neutral")

#==------------------------------------------------------------------------==#
# The computed-name exemption is SUBTREE-scoped, the render walk keeps buffer
# bytes, and the catalog lane is linear on shared trees. Every cell is red on
# 5ad00b5 and traces to one finding id.
#==------------------------------------------------------------------------==#

# -- the exemption is subtree-scoped --
# A name computed by a subtree an outer operator REPLACES is not an output of
# the reference's own input: the reference is a stored-dead name and the
# catalog refuses it. 5ad00b5 exempted it tree-globally (the flat
# computed-set), so expansion passed and the engine raised a raw binder
# error at execute.
(def r3R-e1 (jq/group (jq/from :cat_emp) [:emp] (r3-agg :sum :pay)))
(def r3R-hidden (jq/group r3R-e1 [:emp] (r3-agg :count :emp)))
(assert-errz (fn [] (jq/expand-tree (jq/select r3R-hidden :sum_pay) r3-emp))
  {:error :unknown-column :name :sum_pay}
  "catalog|replaced-subtree-name-is-not-exempt")
# order keys never enter the name check at all (a documented known
# gap) - recorded so the gap is
# visible and a future lane that starts checking them fails this cell
(assert (not (try (do (jq/expand-tree (jq/order r3R-hidden :sum_pay) r3-emp) false)
                  ([ _] true)))
        "catalog|order-keys-are-outside-the-name-check-known-gap")
# the multi-key form: sum_pay was under the INNER group's output only, so it
# is not carried by the replaced node's key list
(assert-errz (fn [] (jq/expand-tree (jq/group r3R-hidden [:emp :sum_pay]
                                                (r3-agg :count :emp)) r3-emp))
  {:error :unknown-column :name :sum_pay}
  "catalog|replaced-subtree-name-refused-as-extra-key")
# a name computed on the JOIN'S LEFT ARM cannot exempt a right-arm qualified
# reference: the right arm's own output decides
(def r3R-cat2 (table :t @{:columns @[:a :b]} :t2 @{:columns @[:c]}))
(def r3R-left (jq/select (jq/from :t)
                         {:expr :get :col :a :alias nil}
                         {:expr :call :op :add
                          :args [{:expr :get :col :a :alias nil} {:expr :lit :value 1}]
                          :as "ab"}))
(def r3R-join (jq/join r3R-left (jq/from :t2 :alias :r) :a :c))
(assert-errz (fn [] (jq/expand-tree
                      (jq/select r3R-join {:expr :get :col "ab" :alias :r} :a)
                      r3R-cat2))
  {:error :unknown-column :name :ab}
  "catalog|computed-name-does-not-cross-join-arms; a string entry reports the :name as a keyword, one column one form")
# the same join, computed name referenced on the arm that COMPUTES it, stays
# exempt (the legitimate positive cell)
(assert-eq (get (jq/expand-tree (jq/select r3R-join :ab :a) r3R-cat2) :columns)
           [:ab :a]
           "catalog|computing-arm-qualified-and-unqualified-refs-pass")

# -- infrastructure corrections (before/after, one cell each) ----------
# (i) output-columns on :sides returned @[] before the fix: that clause was
# an append arm whose walk recursed :left/:right, which an append does not
# have. After: the union of its sides' columns (positional, so repeats).
(assert-eq (jq/output-columns (jq/append (jq/from :cat_emp) (jq/from :cat_emp))
                              r3-emp)
           [:emp :dept :pay :emp :dept :pay]
           "infra-i|append-output-columns-is-side-union")
# (ii) a select's computed :as/:alias was invisible to output-columns (only
# an :expr :get entry reported a name), so an alias over a CALL left nothing
# behind - the cross-arm fixture's left arm answered (nil) and its join was
# unverifiable. After: projected names are reported in order.
# A projected name has ONE form, so the computed "pay1" reports as :pay1.
# built for (a CALL's :as leaving nothing behind) is unchanged and still
# asserted by the :pay1 entry.
(assert-eq (jq/output-columns
             {:node :select
              :input (jq/from :cat_emp)
              :cols [{:expr :get :col :emp :alias nil}
                     {:expr :call :op :add
                      :args [{:expr :get :col :pay :alias nil}
                             {:expr :lit :value 1}]
                      :as "pay1"}]}
             r3-emp)
           [:emp :pay1]
           "infra-ii|select-output-columns-reports-computed-alias (one name form)")
# (iii) known-computed? fell through to local-outputs, so a join/append arm
# UNION (every stored source column) counted as computed and an UNDECLARED name
# was exempted across the arm: the expander passed what the engine refuses.
# After: only a computing node (group aggregate, select :as/:alias) qualifies.
# AMENDED: :c is a real
# column of the right arm :t2, so above the join it is in scope by the union
# rule, not by a computed-name exemption. The exemption claim this cell
# guarded is still covered by the guard cell below (a name on neither arm).
(assert-eq (get (jq/expand-tree (jq/select r3R-join :c) r3R-cat2) :columns)
           [:c]
           "infra-iii|arm-union-is-not-a-computed-name")
(assert-errz (fn [] (jq/expand-tree (jq/select r3R-join :nonesuch) r3R-cat2))
  {:error :unknown-column :name :nonesuch}
  "infra-iii|arm-union-still-refuses-a-true-unknown")

# -- interaction lanes (the rule and the existing rules together) ------
# L1: a pass-through above a computing node forwards its computed names, so a
# reference the input produced stays exempt (order/limit above the select).
(def r4-sel (jq/select (jq/from :t) {:expr :get :col :a :alias nil}
                       {:expr :call :op :add
                        :args [{:expr :get :col :a :alias nil} {:expr :lit :value 1}]
                        :as "ab"}))
(each r4-pt [(fn [x] (jq/order x :ab)) (fn [x] (jq/limit x 5))]
  (assert-eq (get (jq/expand-tree
                    (jq/where (r4-pt r4-sel) (jq/gt (jq/get :ab) (jq/lit 1)))
                    r3R-cat2) :columns)
             [:a :ab]
             "lane1|computed-name-survives-a-pass-through (one name form)"))
# L2: a join has no :input; its scope is the UNION of its arm outputs, so its
# own keys resolve there and a right-arm projection is legal (an arm is never
# judged against the join's key list)
(assert-eq (get (jq/expand-tree
                  (jq/join (jq/from :t2) r4-sel :c :ab) r3R-cat2) :columns)
           [:c :a :ab]
           "lane2|join-key-resolves-in-the-arm-union")
# L3 (unchanged lane, HEAD green): a qualified reference to the computing arm
# stays exempt; an unknown alias is still a name raise. The scope rule never
# widens or narrows the alias lane
(assert-eq (get (jq/expand-tree
                  (jq/select r3R-join {:expr :get :col :ab :alias :t})
                  r3R-cat2) :columns)
           [:ab] "lane3|qualifying-alias-still-exempts-the-arm-name")
(assert-errz (fn [] (jq/expand-tree
                      (jq/select {:node :join :type :inner
                                  :left (jq/from :cat_emp)
                                  :right {:node :from :src :t}
                                  :lkeys [:emp]
                                  :rkeys [:a]}
                                 {:expr :get :col :a :alias :nobody})
                      r3-emp))
  {:error :unknown-column :name :nobody}
  "lane3|unknown-alias-is-still-refused")
# L4 (unchanged lane, HEAD green): an input naming an UNNAMED source has an
# undeterminable scope, so the stored reference defers to the engine
# instead of being refused
(assert-eq (get (jq/expand-tree
                  (jq/select {:node :join :type :inner
                              :left (jq/from :t)
                              :right {:node :from-parquet :path "/tmp/none.parquet"}
                              :lkeys [:a]
                              :rkeys [:z]}
                             :z)
                  r3R-cat2) :columns)
           [:z]
           "lane4|undeterminable-scope-defers-to-engine")
# L5: an unqualified reference binds to the sources on ITS OWN data path. A
# select arm's :a reads :t only, so the join's sibling source :t2 must not be
# asked for it (it would have been refused as an unknown column there)
(assert-eq (get (jq/expand-tree
                  (jq/join (jq/from :t2)
                           (jq/select (jq/from :t) {:expr :get :col :a :alias nil})
                           :c :a)
                  r3R-cat2) :columns)
           [:c :a]
           "lane5|unqualified-ref-binds-to-its-own-data-path")

# -- the input-scope rule for stored references -----------
# A stored reference must appear in the referencing node's own input outputs;
# it is refused when that scope is determinable. (a) a select-expression entry
# above a group that DROPPED the column: the outer group's input is the
# select, and :dept is catalogued on :cat_emp, so per-source strictness alone
# passes it - the reference's own row is what makes it dead.
(def r3R-sel (jq/select (jq/group (jq/from :cat_emp) [:emp] (r3-agg :sum :pay))
                        {:expr :get :col :dept :alias nil}))
(assert-errz (fn [] (jq/expand-tree (jq/group r3R-sel [:dept]
                                          (r3-agg :count :dept)) r3-emp))
  {:error :unknown-column :name :dept}
  "catalog|input-scope-class-refused")
# (b) the where-pred lane: a catalogued column the group DROPPED
(def r3R-g (jq/group (jq/from :cat_emp) [:emp] (r3-agg :sum :pay)))
(assert-errz (fn [] (jq/expand-tree
                      (jq/where r3R-g (jq/gt (jq/get :dept) (jq/lit 1)))
                      r3-emp))
  {:error :unknown-column :name :dept}
  "catalog|where-pred-dropped-column-refused")
# (c) a select entry naming as an output a stored column its input dropped
(assert-errz (fn [] (jq/expand-tree
                      (jq/select r3R-g {:expr :get :col :dept :alias nil})
                      r3-emp))
  {:error :unknown-column :name :dept}
  "catalog|select-expression-output-refused")

# -- positives that must stay green ---------
# the computing group's own aggregate name, projected straight above it
(assert-eq (get (jq/expand-tree (jq/select r3R-g :sum_pay) r3-emp) :columns)
           [:sum_pay] "catalog|computing-group-ref-stays-exempt")
# a computed name forwarded through pass-through operators (order/limit/
# distinct) keeps passing: the boundary is nearest-output OR beneath
(each r3R-pt [(fn [t] (jq/order t :sum_pay))
              (fn [t] (jq/limit t 5))
              (fn [t] (jq/node-distinct t))]
  (assert-eq (get (jq/expand-tree (jq/select (r3R-pt r3R-g) :sum_pay) r3-emp)
                  :columns)
             [:sum_pay]
             "catalog|computed-name-survives-pass-through-operators"))
# a computed name defined below and referenced from a where ABOVE it: the
# where forwards its input's columns, so the group's stored key travels too
(assert-eq (get (jq/expand-tree
                  (jq/where r3R-g (jq/gt (jq/get :sum_pay) (jq/lit 1)))
                  r3-emp) :columns)
           [:emp (quote sum_pay)] "catalog|where-pred-ref-to-a-computed-name-passes")

# -- the catalog lane is linear on shared trees -------
# The per-operator descenders had no identity memo: a diamond of shared
# subtrees cost 2^depth inside expand-tree when a catalog was supplied
# (depth 12 measured ~0.38 s, d=18 ~16 s). Same budget style as the
# fix4/walk cells above.
(assert-eq (under-budget? 500 (fn [] (jq/expand-tree (diamond-tree 16) r3-emp)))
           true "walk|catalog-diamond-16-under-500ms")
(assert-eq (under-budget? 500 (fn [] (jq/expand-tree (join-diamond-tree 14) r3-emp)))
           true "walk|catalog-join-diamond-14-under-500ms")
# the memoised lane still VALIDATES every shared child it meets: a defect in
# a shared subtree is still named (cost changes, decisions do not)
(assert-errz (fn [] (jq/expand-tree
                      (jq/select {:node :append
                                  :sides (tuple r3R-g r3R-g)} :bogus)
                      r3-emp))
  {:error :unknown-column :name :bogus}
  "walk|shared-subtree-still-validated")

#==------------------------------------------------------------------------==#
# Input scope at the determinability
# boundaries, arm-union computed merge, qualified refs, join unions, select
# :as/:alias key spaces. Every cell is RED on aeb9c7a and traces to one
# finding id.
#==------------------------------------------------------------------------==#

# -- the arm union is not a computation ----------------
# A stored column of ONE append side passed above a group whose own output
# lacks it, because the other side's group published the name and
# computed-outputs merged both sides. Now a side's computed names count only
# when they are COLUMNS of the side's own output, position-aligned.
(def r4-app-cat (table :u @{:columns @[:a :c]} :t @{:columns @[:a :b]}))
(defn r4-agg [op c] (r3-agg op c))
(def r4-app-l2 (jq/group (jq/append (jq/from :u)
                                    (jq/group (jq/from :t) [:a] (r4-agg :sum :b)))
                         [:b] (r4-agg :count :b)))
(assert-errz (fn [] (jq/expand-tree r4-app-l2 r4-app-cat))
  {:error :unknown-column :name :b}
  "catalog|append-side-column-above-its-group-is-refused")
(assert-errz (fn [] (jq/expand-tree (jq/select r4-app-l2 :b) r4-app-cat))
  {:error :unknown-column :name :b}
  "catalog|append-side-computed-name-does-not-cross-the-append")
(def r4-app-l3 (jq/group (jq/append (jq/select (jq/from :u) :a :c)
                                    (jq/group (jq/from :t) [:a] (r4-agg :sum :b)))
                         [:b] (r4-agg :count :b)))
(assert-errz (fn [] (jq/expand-tree r4-app-l3 r4-app-cat))
  {:error :unknown-column :name :b}
  "catalog|append-side-column-refused-positional-left")
(assert-errz (fn [] (jq/expand-tree (jq/select r4-app-l3 :b) r4-app-cat))
  {:error :unknown-column :name :b}
  "catalog|append-side-column-refused-positional-left-select")
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/append (jq/select (jq/from :u) :a :c)
                                            (jq/group (jq/from :t) [:a] (r4-agg :sum :b)))
                                 :b)
                      r4-app-cat))
  {:error :unknown-column :name :b}
  "catalog|append-side-column-refused-at-the-append")
# positives: a computed name that IS a column of its side's output passes
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/append (jq/group (jq/from :t) [:a] (r4-agg :sum :b))
                                        (jq/select (jq/from :u) :a :c))
                             :sum_b)
                  r4-app-cat) :columns)
           [:sum_b] "catalog|append-side-computed-column-stays-exempt")

# -- ONE determinability boundary -----------
# A side with a catalogued source is determinable as a scope; a side with an
# unnamed source makes the operator's scope undeterminable. Neither a false
# refusal (parquet side of an append) nor a coercion to () may decide it.
(def r4-pq-cat (table :t1 @{:columns @[:emp :pay]}
                       "/d/p.parquet" @{:columns @[:b :c]}))
(def r4-pq-app (jq/append (jq/from :t1)
                          (jq/from-parquet "/d/p.parquet" :alias :pp)))
# The catalogued parquet side is determinable under
# its alias AND its path, so the appending row is now computable and its
# scope is the position-aligned union. The earlier nil expectation recorded
# the undeterminability, not the rule.
(assert-eq (get (jq/expand-tree
                  (jq/where r4-pq-app (jq/gt (jq/get :b :pp) (jq/lit 1)))
                  r4-pq-cat) :columns)
           [:emp :pay :b :c]
           "catalog|qualified-ref-into-a-catalogued-parquet-side")
(assert-eq (get (jq/expand-tree
                  (jq/where (jq/append (jq/from :t1)
                                       (jq/from-parquet "/d/q.parquet" :alias :qq))
                            (jq/gt (jq/get :b :qq) (jq/lit 1)))
                  r4-pq-cat) :columns)
           nil
           "catalog|unnamed-parquet-side-still-defers")
# a nil side poisons the whole appending scope - it is never coerced to ().
# The side must be one the catalogue does NOT describe, or
# it is determinable and the mechanism has no nil to test.
(assert-eq (jq/output-columns
             (jq/append (jq/from :t1)
                        (jq/from-parquet "/d/uncatalogued.parquet"))
             r4-pq-cat)
           nil
           "catalog|append-side-nil-is-not-an-empty-tuple")
# the uncatalogued JOIN arm defers instead of refusing the arm's own column:
# expand-tree refuses the uncatalogued TABLE, so the parquet arm is the shape
# the deferral lane actually has
(assert-eq (jq/output-columns
             (jq/join (jq/from :t1) (jq/from-parquet "/d/u.parquet") :emp :a)
             r4-pq-cat)
           nil "catalog|join-with-unnamed-arm-is-undeterminable")
# the group above that join defers the catalogued arm's column instead of
# refusing it (it is in scope for the join's union; the unnamed arm may own
# the name, so the engine decides)
(def r4-uj (jq/join (jq/from :t1) (jq/from-parquet "/d/u.parquet") :emp :a))
(assert-eq (get (jq/expand-tree (jq/select r4-uj :emp) r4-pq-cat) :columns)
           [:emp] "catalog|group-above-join-with-unnamed-arm-defers")

# -- a qualified reference under the scope rule ------------
# The qualifier is the WITNESS: an alias-qualified reference must appear in the
# QUALIFIER's own source columns when the qualifier resolves, and is refused
# when that source's scope is determinable and the column is absent.
(def r4-q-cat (table :cat_emp @{:columns @[:emp :dept :pay]}
                          :t @{:columns @[:a :b]}))
(def r4-qJ (jq/join (jq/from :cat_emp)
                    (jq/from-parquet "/tmp/r4q.parquet") :emp :a))
(assert-errz (fn [] (jq/expand-tree
                      (jq/where r4-qJ (jq/gt (jq/get :a :cat_emp) (jq/lit 1)))
                      r4-q-cat))
  {:error :unknown-column :name :a}
  "catalog|qualified-ref-absent-from-qualifier-dropped-column")
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/where r4-qJ
                                           (jq/gt (jq/get :a :cat_emp) (jq/lit 1)))
                                 {:expr :get :col :a :alias :cat_emp})
                      r4-q-cat))
  {:error :unknown-column :name :a}
  "catalog|qualified-ref-dead-column-above-the-where")
# the qualifier's own in-scope column still passes (the operator's own
# columns are undeterminable here - an uncatalogued parquet arm - so the
# assertion is that expansion ACCEPTS the reference)
(assert-eq (catch-err (fn [] (jq/expand-tree
                               (jq/where r4-qJ (jq/gt (jq/get :emp :cat_emp) (jq/lit 1)))
                               r4-q-cat)))
           nil
           "catalog|qualified-ref-in-scope-still-passes")
# an undeterminable qualifier source defers (never a false refusal)
(assert-eq (catch-err (fn [] (jq/expand-tree
                              (jq/where (jq/append (jq/from :t)
                                                   (jq/from-parquet "/d/n.parquet" :alias :nn))
                                        (jq/gt (jq/get :zz :nn) (jq/lit 1)))
                              r4-q-cat)))
           nil
           "catalog|qualified-ref-to-an-unnamed-source-defers")

# -- a deferral is a postponement, not an exemption ---------
# A reference deferred at an inner node (undeterminable scope) and re-emitted
# above an operator whose scope IS determinable must be scope-checked there.
(def r4-d-cat (table :t @{:columns @[:a :b]}))
(def r4-dN (jq/select (jq/join (jq/from :t)
                               (jq/from-parquet "/tmp/r4none.parquet") :a :z)
                      :definitely_not_here))
(assert-eq (get (jq/expand-tree r4-dN r4-d-cat) :columns)
           [:definitely_not_here]
           "catalog|deferred-ref-at-the-deferring-node-stays-live")
(assert-errz (fn [] (jq/expand-tree
                      (jq/where r4-dN (jq/gt (jq/get :definitely_not_here) (jq/lit 1)))
                      r4-d-cat))
  {:error :unknown-column :name :definitely_not_here}
  "catalog|deferred-ref-re-emitted-above-a-where-is-checked")
(assert-errz (fn [] (jq/expand-tree
                      (jq/group r4-dN [:q] (r4-agg :sum :definitely_not_here))
                      r4-d-cat))
  {:error :unknown-column :name :definitely_not_here}
  "catalog|deferred-ref-in-a-group-agg-is-checked")
(assert-eq (get (jq/expand-tree
                  (jq/group r4-dN [:definitely_not_here]
                            (r4-agg :sum :definitely_not_here))
                  r4-d-cat) :columns)
           [:definitely_not_here 'sum_definitely_not_here]
           "catalog|group-key-slot-stays-outside-the-name-check")
(assert-errz (fn [] (jq/expand-tree
                      (jq/where (jq/select (jq/from :t) :a)
                                (jq/gt (jq/get :zz) (jq/lit 1)))
                      r4-d-cat))
  {:error :unknown-column :name :zz}
  "catalog|determinable-control-still-refuses")

#===----------------------------------------------------------------------===#
# Merged-row join scope + per-side key check:
# a join's output row carries BOTH arms, so a
# selector above a join is judged against the union of arm outputs.
#===----------------------------------------------------------------------===#
(def r4-jcat (table :t @{:columns @[:x :y :g]}
                    :u @{:columns @[:x :z]}))

(defn r4-jsel [k] (jq/select (jq/join (jq/from :t) (jq/from :u) :x :x) k))

# the right arm's own column, through the merged row (was a false refusal)
(assert-eq (get (jq/expand-tree (r4-jsel :z) r4-jcat) :columns)
           [:z] "catalog|selector-above-join-sees-right-arm")
(assert-eq (get (jq/expand-tree (r4-jsel :g) r4-jcat) :columns)
           [:g] "catalog|selector-above-join-sees-left-arm")
# a column on NEITHER arm stays refused (the union is not a blanket pass)
(assert-errz (fn [] (jq/expand-tree (r4-jsel :nope) r4-jcat))
  {:error :unknown-column :name :nope}
  "catalog|selector-above-join-refuses-true-unknown")
# the select ECHO is not a scope: a catalogued parquet source's absent
# column stays refused (owner guard: union applies at the join boundary only)
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/from-parquet "/tmp/ap.parquet") :zzz) alias-cat))
  {:error :unknown-column :name :zzz}
  "catalog|select-echo-is-not-a-scope-guard")
# Join keys are checked PER SIDE - each key names a column of
# its OWN arm. A key naming a column of neither arm (or of the other arm
# only) is refused instead of passing silently to the engine.
(assert-errz (fn [] (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) :pay :dname)
                                    r4-jcat))
  {:error :unknown-column :name :pay}
  "catalog|join-key-naming-neither-arm-refused")
(assert-errz (fn [] (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) :x :y)
                                    r4-jcat))
  {:error :unknown-column :name :y}
  "catalog|join-right-key-checked-against-right-arm")
(assert-eq (get (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) :x :x) r4-jcat)
                :columns)
           [:x :y :g :x :z] "catalog|join-keys-valid-untouched")

#===----------------------------------------------------------------------===#
# r4-fix6 - select :as rename reporting
# verified: the tree is NOT corrupted (A4 expands); the defect was the
# reported name - output-columns preferred :col over :as.
#===----------------------------------------------------------------------===#
(def r4-f6-cat (table :t @{:columns @[:a :b]}))
(def r4-f6-src (jq/from :t))
# A renamed projection reports its :as name, not the underlying column.
# The reported name has one form
# (the keyword); the property this cell was built for, :as over :col,
# is unchanged.
(assert-eq (get (jq/expand-tree
                  (jq/select r4-f6-src {:expr :get :col :a :as "ab" :alias nil})
                  r4-f6-cat) :columns)
           [:ab] "catalog|get-with-as-reports-the-as-name")
# A4: a computed entry carrying :as keeps expanding (no tree corruption)
(assert-eq (get (jq/expand-tree
                  (jq/select r4-f6-src
                             {:expr :call :op :add
                              :args [{:expr :get :col :a :alias nil} {:expr :lit :value 1}]
                              :as "ab" :alias nil})
                  r4-f6-cat) :columns)
           [:ab] "catalog|computed-with-as-expands")
# The renamed name is now visible downstream, so a where on it is checked
# against the projection (it exists) rather than silently unverifiable
(assert-eq (get (jq/expand-tree
                  (jq/where (jq/select r4-f6-src {:expr :get :col :a :as "ab" :alias nil})
                            (jq/gt (jq/get "ab") (jq/lit 1)))
                  r4-f6-cat) :columns)
           [:ab] "catalog|renamed-name-visible-downstream")
# a :get entry's :alias is the SOURCE QUALIFIER, never a rename (control)
(assert-eq (get (jq/expand-tree
                  (jq/select r4-f6-src {:expr :get :col :a :alias nil}) r4-f6-cat)
                :columns)
           [:a] "catalog|unaliased-get-reports-its-column")

#===----------------------------------------------------------------------===#
# Pairwise interaction cells on the shared surface
# (scope x exemption x alias x memoisation)
#===----------------------------------------------------------------------===#
(def r4-m-cat (table :t @{:columns @[:a :b]}
                      :u @{:columns @[:a :c]}))

# aliased arm x merged-row scope: the qualifier still wins over the union,
# so the right arm's column is not reachable through the left arm's alias
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/join (jq/from :t :alias :L) (jq/from :u :alias :R) :a :a)
                                 {:expr :get :col :c :alias :L})
                      r4-m-cat))
  {:error :unknown-column :name :c}
  "catalog|alias-scope-beats-merged-row-union")
# the same column through its OWN arm is in scope (the union rule is intact)
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/join (jq/from :t :alias :L) (jq/from :u :alias :R) :a :a)
                             {:expr :get :col :c :alias :R})
                  r4-m-cat) :columns)
           [:c] "catalog|alias-scope-admits-own-arm")
# computed x merged-row scope, control: the group ABOVE the join expands and
# reports its keys plus its aggregate
(assert-eq (get (jq/expand-tree
                  (jq/group (jq/join (jq/from :t) (jq/from :u) :a :a)
                            [:b] {:expr :agg :agg :sum
                                  :arg {:expr :get :col :a :alias nil}
                                  :as "s_a"})
                  r4-m-cat) :columns)
           [:b 'sum_a] "catalog|group-above-join-reports-keys-and-aggs")
# KNOWN GAP: a SELECT above that
# group still refuses the group's own key. Pre-existing (the group itself
# refuses too); widening the scope here would re-open the append
# bypass, so it stays a recorded residual.
# memoisation x scope: a shared (diamond) join subtree is judged once and
# deterministically - the same verdict twice in one process
(def r4-m-shared (jq/join (jq/from :t) (jq/from :u) :a :a))
(def r4-m-q (jq/select (jq/where r4-m-shared (jq/gt (jq/get :c) (jq/lit 1))) :c))
(assert-eq (get (jq/expand-tree r4-m-q r4-m-cat) :columns)
           [:c] "catalog|shared-join-scope-stable-run1")
(assert-eq (get (jq/expand-tree r4-m-q r4-m-cat) :columns)
           [:c] "catalog|shared-join-scope-stable-run2")
# deferral x merged-row: an uncatalogued parquet arm defers, it must not
# turn the union into a blanket pass for a true-unknown name
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/join (jq/from :t) (jq/from-parquet "/tmp/none.parquet") :a :a)
                             :b)
                  r4-m-cat) :columns)
           [:b] "catalog|deferring-arm-keeps-known-arm-in-scope")

#===----------------------------------------------------------------------===#
# Reference scope lanes.
#===----------------------------------------------------------------------===#
(def r6-cat (table :t @{:columns @[:x :y :g]}
                   :u @{:columns @[:x :z]}
                   :u2 @{:columns @[:x :w]}))
(def r6-pcat (table :t @{:columns @[:t1 :t2]}
                    :u @{:columns @[:u1 :u2]}))
(defn r6-j [l r k1 k2] (jq/join l r k1 k2))
(defn r6-jtu [] (r6-j (jq/from :t) (jq/from :u) :x :x))

# -- the per-source lane agrees with `near` ------
# The union died above a select, a where and a query wrapper,
# because the witness walk stopped after a fixed five pass-throughs and had
# no select case. The row below the selector is still the merged join row.
(assert-eq (get (jq/expand-tree (jq/select (jq/select (r6-jtu) :z) :z) r6-cat)
                :columns)
           [:z] "catalog|union-survives-select-above-select")
(assert-eq (get (jq/expand-tree (jq/where (jq/select (r6-jtu) :z)
                                          (jq/gt (jq/get :z) (jq/lit 1)))
                                r6-cat) :columns)
           [:z] "catalog|union-survives-where-above-select")
(assert-eq (get (jq/expand-tree {:node :query :tree (jq/select (r6-jtu) :z)} r6-cat)
                :columns)
           [:z] "catalog|union-survives-query-wrapper")
# a true-unknown column above the same chain is still refused
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/select (r6-jtu) :zzz) :zzz) r6-cat))
  {:error :unknown-column :name :zzz}
  "catalog|chain-still-refuses-true-unknown")
# the append lane: the appending row is the sides' positional alignment
(defn r6-app [] (jq/append (jq/select (jq/from :u) :x :z)
                           (jq/select (jq/from :t) :x :y)))
(assert-eq (get (jq/expand-tree (jq/select (r6-app) :z) r6-cat) :columns)
           [:z] "catalog|select-above-append-sees-first-side-column")
(assert-eq (get (jq/expand-tree (jq/select (jq/select (r6-app) :z) :z) r6-cat) :columns)
           [:z] "catalog|append-union-survives-a-second-select")
# A SELECT above a group now
# sees the group's own key. The group is a reshaping boundary whose row is its
# keys plus its aggregate entries.
(assert-eq (get (jq/expand-tree
                  (jq/select (jq/group (r6-jtu) [:z] {:expr :agg :agg :count
                                                      :arg (jq/get :x)})
                             :z)
                  r6-cat) :columns)
           [:z] "catalog|select-above-group-sees-the-groups-key")
# a name that is neither a group key nor its aggregate is still refused
(assert-errz (fn [] (jq/expand-tree
                      (jq/select (jq/group (r6-jtu) [:z] {:expr :agg :agg :count
                                                          :arg (jq/get :x)})
                                 :y)
                      r6-cat))
  {:error :unknown-column :name :y}
  "catalog|group-neither-key-nor-agg-refused")

# -- deferral and qualifier-witness before re-emission -----
# M2's C1: a qualified reference to an UNCATALOGUED parquet arm DEFERS. It
# refuses today because the row-union / re-emission clauses fire first.
(def r6-ecat (table :cat_emp @{:columns @[:emp :dept :pay]}
                    :t @{:columns @[:a :b]}))
(defn r6-jp [] (r6-j (jq/from :cat_emp)
                     (jq/from-parquet "/d/p.parquet" :alias :pp) :emp :a))
(assert-eq (get (jq/expand-tree
                  (jq/where (r6-jp) (jq/gt (jq/get :qq :pp) (jq/lit 1))) r6-ecat)
                :columns)
           nil "catalog|qualified-uncatalogued-arm-defers")
# control: a qualified reference to the CATALOGUED arm's column stays green
(assert-eq (get (jq/expand-tree
                  (jq/where (r6-jp) (jq/gt (jq/get :a :pp) (jq/lit 1))) r6-ecat)
                :columns)
           nil "catalog|qualified-known-column-stays-green")
# control: a qualified reference to a catalogued source LACKING the column is
# still a refusal (the qualifier IS the witness - :out)
(assert-errz (fn [] (jq/expand-tree
                      (jq/where (r6-jp) (jq/gt (jq/get :qq :cat_emp) (jq/lit 1)))
                      r6-ecat))
  {:error :unknown-column :name :qq}
  "catalog|qualified-catalogued-miss-still-refuses")

# -- key slots routed per-side, both key forms --
# a left key naming only the RIGHT arm is refused in BOTH forms (the
# (keyword? k) gate meant a string key was never checked at all)
(assert-errz (fn [] (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) :z :x) r6-cat))
  {:error :unknown-column :name :z}
  "catalog|left-key-naming-only-the-right-arm-refused-kw")
(assert-errz (fn [] (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) "z" "x") r6-cat))
  {:error :unknown-column :name :z}
  "catalog|left-key-naming-only-the-right-arm-refused-str (the string form reports :name as a keyword)")
(assert-errz (fn [] (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) :x :g) r6-cat))
  {:error :unknown-column :name :g}
  "catalog|right-key-naming-only-the-left-arm-refused-kw")
(assert-errz (fn [] (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) "x" "g") r6-cat))
  {:error :unknown-column :name :g}
  "catalog|right-key-naming-only-the-left-arm-refused-str (the string form reports :name as a keyword)")
# KEY-SLOT EQUIVALENCE: legitimate same-name keys stay green in BOTH forms
(assert-eq (get (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) :x :x) r6-cat) :columns)
           [:x :y :g :x :z] "catalog|same-name-keys-green-kw")
(assert-eq (get (jq/expand-tree (r6-j (jq/from :t) (jq/from :u) "x" "x") r6-cat) :columns)
           [:x :y :g :x :z] "catalog|same-name-keys-green-str")
# the unnamed arm: a key naming the UNNAMED (parquet) arm's column. This
# cell is corrected: the earlier reading
# called it a key-slot reference, but the reference here is the WHERE's own
# predicate column - not a key slot - and the boundary rule judges it at the
# selector. The projection :dnh proves the select's row; :z has no supplier
# (the parquet arm is unresolvable), so it is REFUSED, never deferred.
# The key-slot lane itself stays at the join.
(def r6-dcat (table :t @{:columns @[:a :b]}))
(defn r6-dn [] (jq/select (r6-j (jq/from :t)
                                (jq/from-parquet "/d/none.parquet" :alias :nn) :a :z)
                          :dnh))
(assert-errz (fn [] (jq/expand-tree
                      (jq/where (r6-dn) (jq/gt (jq/get :z) (jq/lit 1)))
                      r6-dcat))
  {:error :unknown-column :name :z}
  "catalog|published-row-without-a-supplier-refuses")
(assert-errz (fn [] (jq/expand-tree (jq/where (r6-dn) (jq/gt (jq/get :dnh) (jq/lit 1)))
                                    r6-dcat))
  {:error :unknown-column :name :dnh}
  "catalog|deferring-arm-does-not-admit-unknown-name")

# -- a QUALIFIED witness settles, and a publishing
# select above it never narrows the engine-served set -----------------------
# The r6 probe's own cells. A qualifier naming a source the catalog neither
# describes is a witness that CANNOT ANSWER (the ref defers); one it
# describes and that carries the name is a PROVEN witness (serves); one
# that describes the catalogued arm but lacks the name refuses. The control
# pins that publishing a projection changes none of the three.
(def r6-q-cat {:cat_emp {:columns [:emp :dept :pay]} :t {:columns [:a :b]}})
(defn r6-qp []
  (jq/join (jq/from :cat_emp)
           (jq/from-parquet "/d/p.parquet" :alias :pp) :emp :a))
(defn r6-q [f] (jq/expand-tree (f) r6-q-cat))
(assert-eq (struct? (try (r6-q (fn [] (jq/where (r6-qp) (jq/gt (jq/get :qq :pp) (jq/lit 1)))))
                         ([e] nil)))
           true "catalog|unnamed-qualifier-below-any-select")
(assert-eq (get (r6-q (fn [] (jq/where (jq/select (r6-qp) :emp)
                                       (jq/gt (jq/get :qq :pp) (jq/lit 1))))) :columns)
           [:emp] "catalog|unnamed-arm-qualified-ref-above-a-select-defers")
(assert-eq (get (r6-q (fn [] (jq/where (jq/select (r6-qp) :emp)
                                       (jq/gt (jq/get :dept :cat_emp) (jq/lit 1))))) :columns)
           [:emp] "catalog|proven-qualifier-above-a-select-serves")
(assert-errz (fn [] (r6-q (fn [] (jq/where (jq/select (r6-qp) :emp)
                                          (jq/gt (jq/get :qq :cat_emp) (jq/lit 1))))))
  {:error :unknown-column :name :qq}
  "catalog|proven-qualifier-lacking-the-name-refuses")

# -- duplicate source aliases refused at expansion ----------------
(assert-errz (fn [] (jq/expand-tree
                      (r6-j (jq/from :t :alias :e1) (jq/from :u :alias :e1) :x :x)
                      r6-cat))
  {:error :malformed-tree :why :duplicate-alias :alias :e1}
  "catalog|duplicate-source-alias-refused")
(assert-eq (get (jq/expand-tree
                  (r6-j (jq/from :t :alias :e1) (jq/from :u :alias :e2) :x :x) r6-cat)
                :columns)
           [:x :y :g :x :z] "catalog|distinct-aliases-pass")

# -- alias semantics ----------
# The qualifier table is a flat, first-alias-wins map over the whole tree. A
# qualifier naming the arm that OWNS the column is judged by that arm and
# passes; a qualifier naming the other arm (or a bare source name that is not
# an alias of any arm) is refused. This is the CURRENT behaviour, recorded, and
# documented in the alias-semantics note.
(defn r6-p29d [q] (jq/expand-tree
                    (jq/where (r6-j (jq/from :t :alias :u1) (jq/from :u :alias :u2) :x :x)
                              (jq/gt (jq/get :y q) (jq/lit 1)))
                    r6-cat))
(assert-eq (get (r6-p29d :u1) :columns)
           [:x :y :g :x :z]
           "catalog|qualifier-naming-the-owning-arm-passes")
(assert-errz (fn [] (r6-p29d :u2))
  {:error :unknown-column :name :y}
  "catalog|qualifier-naming-the-other-arm-refused")

# -- projection hygiene ---------------
# A select entry's :as is a NAME, and a name has one form. A string entry
# reported ("money") while the keyword form reported (:money), so one tree had
# two different output rows depending on how its author wrote the same rename.
(def r6-hy-cat {:cat_emp {:columns [:emp :dept :pay]}})
(defn r6-hy-as [nm]
  (get (jq/expand-tree
        (jq/select (jq/from :cat_emp) {:expr :get :col :pay :as nm})
        r6-hy-cat) :columns))
(assert-eq (r6-hy-as "money") [:money]
          "catalog|string-as-name-reports-the-keyword-form")
(assert-eq (r6-hy-as :money) [:money]
          "catalog|keyword-as-name-unchanged")
(assert-eq (r6-hy-as "money") (r6-hy-as :money)
          "catalog|both-name-forms-give-one-output-row")

# An ABSENT :cols is an absent declaration, never a declared-empty
# projection. The node hands its input's row on, so that row is its output:
# reporting () made the pass-through lie, and the lie propagated - a select
# above the empty one refused a column the tree really carried, and an append
# read a real side as an empty one and raised a column-count mismatch.
(def r6-hy-pq {:node :from-parquet :path "/d/p.parquet"})
(defn r6-hy-cols [t] (get (jq/expand-tree t r6-hy-cat) :columns))
(assert-eq (r6-hy-cols (jq/select (jq/from :cat_emp))) [:emp :dept :pay]
          "catalog|cols-less-select-over-a-table-passes-its-row-through")
(assert-eq (r6-hy-cols (jq/select (jq/select (jq/from :cat_emp)) :emp)) [:emp]
          "catalog|cols-less-select-does-not-refuse-a-carried-column")
(assert-eq (r6-hy-cols (jq/select r6-hy-pq)) nil
          "catalog|cols-less-select-over-an-uncatalogued-arm-stays-undecidable")
(assert-eq (r6-hy-cols (jq/append (jq/select (jq/from :cat_emp)) (jq/from :cat_emp)))
          [:emp :dept :pay :emp :dept :pay]
          "catalog|append-reads-a-cols-less-side-as-the-row-it-carries")

# -- the chain launder does not reproduce -----------------------------------------------------------------------
# The bare-join cells above must keep their pre-publish deferral. A DECLARED
# projection anywhere in the chain ends that deferral: every name is then
# judged (served where a supplier backs it, refused otherwise), so neither
# `:z` (uncatalogued) nor `:zzz` (invented) is laundered through the
# projections above them. The boundary rule already decides this through the
# stored-reference lane; the redundant extra clause was
# withdrawn, and these cells are what keeps it decided.
(def r6-ch-cat {:t @{:columns @[:a :b]}
                :u @{:columns @[:a :c]}})
(defn r6-ch-j []
  (jq/join (jq/from :t) (jq/from :u) :a :a))
(defn r6-ch-pq ()
  (jq/join (jq/from :t) (jq/from-parquet "/d/nope.parquet" :alias :nn) :a :z))
(assert-eq (get (jq/expand-tree (jq/select (jq/select (r6-ch-j) :a) :a)
                                r6-ch-cat) :columns)
           [:a] "catalog|a-declared-projection-serves-a-supplied-name")
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/select (r6-ch-j) :a) :zzz)
                                    r6-ch-cat))
  {:error :unknown-column :name :zzz}
  "catalog|the-outer-projection-cannot-vouch-for-another-name")
(assert-errz (fn [] (jq/expand-tree
                     (jq/select (jq/select (jq/select (r6-ch-pq) :a) :a) :zzz)
                     r6-ch-cat))
  {:error :unknown-column :name :zzz}
  "catalog|chain-launder-refused-through-a-chain")
(assert-errz (fn [] (jq/expand-tree (jq/where (jq/select (r6-ch-pq) :a)
                                              (jq/gt (jq/get :z) (jq/lit 1)))
                                    r6-ch-cat))
  {:error :unknown-column :name :z}
  "catalog|the-uncatalogued-arms-name-is-refused-above-a-select")

# -- a single aggregate in a non-tuple form (ad-hoc finding) ----------
# The group constructor splices its variadic aggregates, so a bare aggregate
# struct reached the walk as its own one-element collection, and a vector
# literal folded it one level deeper. Both now normalise to the aggregate
# node the walk judges.
(def r6-ag-cat {:t @{:columns @[:x]}})
(assert-eq (get (jq/expand-tree
                 (jq/group (jq/from :t) [:x]
                           {:expr :agg :agg :count :arg (jq/get :x)})
                 r6-ag-cat)
                :columns)
           [:x 'count_x]
           "catalog|a-struct-form-aggregate-is-one-aggregate")
(assert-eq (get (jq/expand-tree
                 (jq/group (jq/from :t) [:x] [(jq/agg-count (jq/get :x))])
                 r6-ag-cat)
                :columns)
           [:x 'count_x]
           "catalog|a-vector-form-aggregate-is-one-aggregate")
(assert-errz (fn [] (jq/expand-tree
                     (jq/group (jq/from :t) [:x] [(jq/agg-count (jq/get :zzz))])
                     r6-ag-cat))
  {:error :unknown-column :name :zzz}
  "catalog|a-vector-form-aggregate-names-its-unproven-column")

# -- the uncatalogued-arm ownership question, PINNED AS CURRENT --------
# These cells record today's behaviour, not a settled rule: an unreadable
# join arm may legitimately own a name the checker cannot see, and the
# ownership question is carried by changes/findings-ownership-uncatalogued-arms.md.
# Whoever decides ownership must move these cells deliberately.
(def r6-own-cat {:t @{:columns @[:a :b]}})
(def r6-own-catp {:t @{:columns @[:a :b]} "/d/p.parquet" @{:columns @[:z]}})
(defn r6-own-uj []
  (jq/join (jq/from :t) (jq/from-parquet "/d/p.parquet" :alias :pp) :a :z))
(assert-eq (get (jq/expand-tree (jq/select (r6-own-uj) :zzz) r6-own-cat) :columns)
           [:zzz]
           "catalog|F-OWN-1 an unqualified target over an unreadable arm is served")
(assert-errz (fn [] (jq/expand-tree (jq/select (r6-own-uj) :zzz) r6-own-catp))
  {:error :unknown-column :name :zzz}
  "catalog|F-OWN-2 the same tree refuses once the arm is readable")
(assert-eq (get (jq/expand-tree (jq/order (r6-own-uj) :z) r6-own-cat) :columns)
           nil
           "catalog|F-OWN-3 an unreadable arm makes the whole declared row undeterminable (nil), never a narrowed one")

#==------------------------------------------------------------------------==#
# The group-argument leak and aggregate-argument spelling
#==------------------------------------------------------------------------==#

# -- a group's aggregate ARGUMENT is the group's own scope -----------
# The argument is judged against the group's INPUT; the row the group
# PUBLISHES is its keys plus its computed names. Before the fix every node
# above the group re-judged the argument against the published row, so a
# selector above a group refused a real column (the divergence class).
(def cr9-cat (table :t @{:columns @[:a :b]} :u @{:columns @[:a :c]}))
(defn cr9-j [] (jq/join (jq/from :t) (jq/from :u) :a :a))
(defn cr9-g [op c] (jq/group (cr9-j) [:b] (r3-agg op c)))
(assert-eq (get (jq/expand-tree (jq/select (cr9-g :count :c) :b) cr9-cat) :columns)
           [:b]
           "catalog|selector-above-a-group-serves-a-published-key")
(assert-eq (get (jq/expand-tree (jq/select (cr9-g :count :c) :count_c) cr9-cat) :columns)
           [:count_c]
           "catalog|selector-above-a-group-serves-a-published-computed-name")
(assert-eq (get (jq/expand-tree (jq/order (cr9-g :count :c) :b) cr9-cat) :columns)
           [:b (symbol "count_c")]
           "catalog|order-above-a-group-sees-the-published-row")
(assert-eq (get (jq/expand-tree (jq/where (cr9-g :count :c)
                                          (jq/gt (jq/get :count_c) (jq/lit 1)))
                                cr9-cat)
                :columns)
           [:b (symbol "count_c")]
           "catalog|where-above-a-group-sees-the-published-row")
# the guard direction: a name the group's published row does NOT carry is
# still refused - the argument leaking out must not become a blanket pass
(assert-errz (fn [] (jq/expand-tree (jq/select (cr9-g :count :c) :c) cr9-cat))
  {:error :unknown-column :name :c}
  "catalog|the-argument-is-not-published-above-the-group")
(assert-errz (fn [] (jq/expand-tree (jq/select (cr9-g :count :c) :zzz) cr9-cat))
  {:error :unknown-column :name :zzz}
  "catalog|an-outsider-name-is-still-refused-above-a-group")
# the argument is still checked INSIDE the group: a name its input lacks
# refuses there, so the exemption is scope, not a skip
(assert-errz (fn [] (jq/expand-tree (jq/group (jq/from :t) [:b] (r3-agg :count :c)) cr9-cat))
  {:error :unknown-column :name :c}
  "catalog|the-argument-is-checked-inside-the-group")

# -- one aggregate node whatever the argument's spelling -------------
# a bare keyword argument names a column like (get :c) does; before the fix
# the constructors stored it verbatim and the walk refused the node itself
(assert-eq (get (jq/expand-tree (jq/group (cr9-j) [:b] (jq/agg-count :c)) cr9-cat) :columns)
           [:b 'count_c]
           "catalog|bare-keyword-aggregate-argument-expands")
(assert-eq (get (jq/expand-tree (jq/group (cr9-j) [:b] (jq/agg-count "c")) cr9-cat) :columns)
           [:b 'count_c]
           "catalog|bare-string-aggregate-argument-expands")
(assert-eq (jq/agg-count :c) (jq/agg-count (jq/get :c))
           "nocatalog|the-bare-and-get-spellings-are-one-node")
(assert-eq (get (jq/expand-tree (jq/select (jq/group (cr9-j) [:b] (jq/agg-count :c)) :b)
                                cr9-cat)
                :columns)
           [:b]
           "catalog|a-bare-keyword-aggregate-under-a-selector")
# a malformed aggregate keeps refusing: the spelling fix must not admit junk
(assert-errz (fn [] (jq/expand-tree (jq/group (cr9-j) [:b] {:expr :agg :agg :count :arg 42})
                                    cr9-cat))
  {:error :malformed-tree :why :group-agg}
  "catalog|a-literal-aggregate-argument-stays-malformed")

# -- catalogue presence never flips a REFERENCE VERDICT --------------
# Union MEMBERSHIP is what the
# catalogue decides (a bare from-parquet arm is opaque unless its own column
# list stands on its own); whether a REFERENCE can be decided never depends
# on the catalogue. The flip this section guards: `where :zzz` over
# an unnamed arm deferred uncatalogued and REFUSED catalogued - the same
# tree, two verdicts, from one catalogue entry. One predicate, one answer.
(defn cr9-uj [] (jq/join (jq/from :t) (jq/from-parquet "/tmp/cr9-none.parquet" :alias :pp) :a :a))
(def cr9-cat-none {:t {:columns [:a :b]}})
(def cr9-cat-shared {:t {:columns [:a :b]} :pp {:columns [:a :b]}})
(defn cr9-defers? [t cat]
  (nil? (get (jq/expand-tree t cat) :columns)))
# the flip itself: both catalogue settings reach the SAME undecided answer
(assert (cr9-defers? (jq/where (cr9-uj) (jq/gt (jq/get :zzz) (jq/lit 1))) cr9-cat-none)
        "nocatalog|where-on-an-uncatalogued-arm-defers")
# the falsified claim and its replacement: cataloguing the alias NEVER
# turns the undecided reference into a refusal. It may make the arm's
# columns known (union membership), so the row can become determinate -
# that is a wider answer, not a flipped verdict. A refusal here is the bug
(assert (not (try (do (jq/expand-tree (jq/where (cr9-uj) (jq/gt (jq/get :zzz) (jq/lit 1)))
                                     cr9-cat-none) false)
                  ([ _] true)))
        "nocatalog|the-where-lane-lesser-never-refuses")
(assert (not (try (do (jq/expand-tree (jq/where (cr9-uj) (jq/gt (jq/get :zzz) (jq/lit 1)))
                                     cr9-cat-shared) false)
                  ([ _] true)))
        "catalog|the-where-lane-never-refuses-under-a-shared-block-alias")
# the passthrough lane: a declared projection decides its own row, so the
# reference serves at BOTH catalogue settings
(assert-eq (get (jq/expand-tree (jq/select (cr9-uj) :zzz) cr9-cat-none) :columns)
           [:zzz]
           "nocatalog|a-declared-projection-on-an-uncatalogued-arm-serves")
(assert-eq (get (jq/expand-tree (jq/select (cr9-uj) :zzz) cr9-cat-shared) :columns)
           [:zzz]
           "catalog|cataloguing-the-alias-flips-no-passthrough-verdict")

# -- a constant where predicate is served ----------------------------
# `WHERE 1` is legal SQL. The where slot judges a TRUTH VALUE; the group slot
# judges NAMES - different slots, not opposite policies.
(assert-eq (get (jq/expand-tree (jq/where (jq/from :t) (jq/lit 1)) cr9-cat) :columns)
           [:a :b]
           "catalog|a-constant-where-predicate-is-served")
(assert-errz (fn [] (jq/expand-tree (jq/where (jq/from :t) (jq/gt (jq/get :nope) (jq/lit 5)))
                                    cr9-cat))
  {:error :unknown-column :name :nope}
  "catalog|a-reference-predicate-on-a-missing-column-is-still-refused")

# -- one name, one form ---------------------------------------------
# A string key and a keyword key name the same column, so :unknown-column
# reports ONE form whatever the entry form.
(defn cr9-name-of [f]
  (try (do (f) nil) ([e] (get e :name))))
(assert-eq (cr9-name-of (fn [] (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) "q" "a") cr9-cat)))
           :q
           "catalog|a-string-key-reports-a-keyword-name")
(assert-eq (cr9-name-of (fn [] (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) "q" "a") cr9-cat)))
           (cr9-name-of (fn [] (jq/expand-tree (jq/join (jq/from :t) (jq/from :u) :q :a) cr9-cat)))
           "catalog|both-key-forms-report-the-same-name")

# ---- group argument and qualifier-spelling cells ----
# The behaviours asserted: the malformed
# aggregate class (one normalised node) and the qualifier
# naming the owning arm passes, in every spelling.

(def cr10-j (jq/join (jq/from :t) (jq/from :u) :a :a))
(defn cr10-cols [f]
  (try (get (f) :columns) ([e] @{:error (get e :error) :why (get e :why)})))
(defn cr10-g [agg] (jq/group cr10-j [:b] agg))

# A literal aggregate argument refuses the
# malformed class; it does NOT publish a computed name (the `count_0`
# phantom). A string literal and an arbitrary expression refuse the same
# way, so no non-reference argument ever reaches a computed name
(assert-eq (cr10-cols (fn [] (jq/expand-tree (cr10-g (jq/agg-count (jq/lit 5))) cr9-cat)))
           @{:error :malformed-tree :why :group-agg}
           "catalog|a-literal-agg-argument-refuses")
(assert-eq (cr10-cols (fn [] (jq/expand-tree (cr10-g (jq/agg-count 5)) cr9-cat)))
           @{:error :malformed-tree :why :group-agg}
           "catalog|a-raw-scalar-agg-argument-refuses")
(assert-eq (cr10-cols (fn [] (jq/expand-tree (cr10-g (jq/agg-count (jq/add (jq/get :a) (jq/lit 1)))) cr9-cat)))
           @{:error :malformed-tree :why :group-agg}
           "catalog|an-expression-agg-argument-refuses")

# The keyword, string and get spellings of one argument
# are ONE normalised node
(assert-eq (jq/agg-count :c) (jq/agg-count "c")
           "catalog|the-string-spelling-is-the-keyword-node")
(assert-eq (jq/agg-count :c) (jq/agg-count (jq/get :c))
           "catalog|the-get-spelling-is-the-keyword-node")
(assert-eq (cr10-cols (fn [] (jq/expand-tree (cr10-g (jq/agg-count "c")) cr9-cat)))
           (cr10-cols (fn [] (jq/expand-tree (cr10-g (jq/agg-count :c)) cr9-cat)))
           "catalog|both-agg-argument-spellings-expand-alike")

# The path lane is catalogue-blind - which KEY the caller
# catalogued the parquet arm under decides union membership only, never a
# verdict. The same tree over the SAME catalog content, keyed once by the
# arm's alias and once by its path, must answer identically on every lane
(def cr10-alias-cat (table :t @{:columns @[:a :b]} :q @{:columns @[:c :d]}))
(def cr10-path-cat (table :t @{:columns @[:a :b]} "/p/q.parquet" @{:columns @[:c :d]}))
(defn cr10-pj [] (jq/join (jq/from :t) (jq/from-parquet "/p/q.parquet" :alias :q) :a :a))
(assert-eq (cr10-cols (fn [] (jq/expand-tree (cr10-pj) cr10-path-cat)))
           (cr10-cols (fn [] (jq/expand-tree (cr10-pj) cr10-alias-cat)))
           "catalog|the-path-keyed-join-row-is-the-alias-keyed-row")
(assert-eq (cr10-cols (fn [] (jq/expand-tree (jq/where (cr10-pj) (jq/gt (jq/get :c) (jq/lit 1))) cr10-path-cat)))
           (cr10-cols (fn [] (jq/expand-tree (jq/where (cr10-pj) (jq/gt (jq/get :c) (jq/lit 1))) cr10-alias-cat)))
           "catalog|a-path-keyed-entry-changes-no-where-verdict")
(assert-eq (cr10-cols (fn [] (jq/expand-tree (jq/select (cr10-pj) :c) cr10-path-cat)))
           (cr10-cols (fn [] (jq/expand-tree (jq/select (cr10-pj) :c) cr10-alias-cat)))
           "catalog|a-path-keyed-entry-changes-no-select-verdict")

# A qualifier naming the owning arm passes in every
# spelling - the string form is the keyword form, and the error site
# never reports the qualifier in place of the column
(assert-eq (cr10-cols (fn [] (jq/expand-tree (jq/select (jq/from :t) (jq/get :b "t")) cr10-alias-cat)))
           (cr10-cols (fn [] (jq/expand-tree (jq/select (jq/from :t) (jq/get :b :t)) cr10-alias-cat)))
           "catalog|the-string-qualifier-is-the-keyword-qualifier")

# -- both-keying resolution cells -----------------------------------------
# G1: every resolution site reads EVERY key a source answers
# to. A parquet arm catalogued under its PATH alone and one catalogued under
# its ALIAS alone must answer the same verdict for the same reference; and
# an arm catalogued under neither must defer, never refuse.
(def r10-path-cat {:t {:columns [:a :b]} "/tmp/r10/u.parquet" {:columns [:c :d]}})
(def r10-alias-cat {:t {:columns [:a :b]} :pu {:columns [:c :d]}})
(defn r10-cols [cat f] (try (do (get (jq/expand-tree (f) cat) :columns)) ([e] (get e :name))))
(defn r10-parq-join [jf] (jf (jq/join (jq/from :t) (jq/from-parquet "/tmp/r10/u.parquet" :alias :pu) :a :c)))
(defn r10-parq-bare [jf] (jf (jq/join (jq/from :t) (jq/from-parquet "/tmp/r10/u.parquet") :a :c)))
# both keyings agree on a SERVED column, in every lane
(each [r10-lane r10-mk] [["select" (fn [t] (jq/select t :c))]
                         ["where" (fn [t] (jq/where t (jq/gt (jq/get :c) (jq/lit 1))))]
                         ["group" (fn [t] (jq/group t [:a] (jq/agg-count :c)))]]
  (assert-eq (r10-cols r10-path-cat (fn [] (r10-parq-bare r10-mk)))
             (r10-cols r10-alias-cat (fn [] (r10-parq-join r10-mk)))
             (string "catalog|both-keyings-one-verdict " r10-lane "")))
# and agree on a REFUSED column
(each [r10-lane r10-mk] [["select" (fn [t] (jq/select t :zzz))]
                         ["where" (fn [t] (jq/where t (jq/gt (jq/get :zzz) (jq/lit 1))))]
                         ["group" (fn [t] (jq/group t [:a] (jq/agg-count :zzz)))]]
  (assert-eq (r10-cols r10-path-cat (fn [] (r10-parq-bare r10-mk)))
             (r10-cols r10-alias-cat (fn [] (r10-parq-join r10-mk)))
             (string "catalog|both-keyings-one-refusal " r10-lane "")))
# a SHARED metadata block describes no arm: the alias carries the same list
# as the table, so the arm is unnamed and the lane DEFERS.
# The WHERE lane is the one that can defer - a select's declared projection
# serves its own row (the select passthrough), so it is not this witness
(assert-eq (r10-cols {:t {:columns [:a :b]} :pp {:columns [:a :b]}}
                     (fn [] (r10-parq-join
                              (fn [t] (jq/where t (jq/gt (jq/get :zzz) (jq/lit 1)))))))
           nil
           "catalog|a-shared-block-leaves-the-arm-unnamed")
# B2: a malformed OPERATOR refuses with the same tag as a
# malformed argument - it never escapes to the expression-name fallback
(assert-errz (fn [] (jq/expand-tree
                      (jq/group (jq/from :t) [:a] {:expr :agg :agg :bogus :arg (jq/col2 :a)})
                      {:t {:columns [:a :b]}}))
  {:error :malformed-tree :why :group-agg}
  "catalog|a-malformed-operator-refuses-tagged")
# B3 / R3 (v0.7.3 item 3 clarification): the wrapper spellings are ONE node
(assert (deep= (jq/col2 "c") (jq/col2 :c))
        "wrapper-spellings-one-node")
(assert (deep= (jq/agg-count (jq/col2 "c")) (jq/agg-count :c))
        "wrapper-spellings-one-aggregate-node")
# A BARE select entry is a name in
# either spelling. Before this the string entry published ("a") and the
# keyword entry (:a) - two output rows for one name.
(def r2-cat (let [c @{}] (put c :t {:columns [:a :q]}) c))
(assert-eq (get (jq/expand-tree (jq/select (jq/from :t) "a") r2-cat) :columns)
           (get (jq/expand-tree (jq/select (jq/from :t) :a) r2-cat) :columns)
           "r2|bare-select-string-and-keyword-one-output-row")
(assert-eq (get (jq/expand-tree (jq/select (jq/from :t) "a") r2-cat) :columns)
           [:a] "r2|bare-string-select-entry-publishes-keyword")


# ---- entry writer identity ------------------------------------------
# The :writer field is CALLER TESTIMONY (the engine reads it, never derives
# an entry without it keeps the unamended walk exactly. Cells mirror the
# catalogue-lane model's runs and the absent-mode floor witnesses (the
# behaviour of the unamended surface).
(def v11-arm (jq/from-parquet "v11a.parquet" :alias :wa))
(defn v11-err [f]
  (def e (catch-err f))
  (when e @{:error (get e :error) :name (get e :name)}))
(defn v11-served? [c cat]
  (nil? (v11-err (fn [] (jq/expand-tree (jq/select v11-arm c) cat)))))

# -- the absent-mode floor: no field anywhere, exactly
# the 2a behaviour: an alien agreeing copy silences the arm's own
# entry, so :a is refused while the arm stays described by its other entry
(assert-errz (fn [] (jq/expand-tree (jq/select v11-arm :a)
                                    {:wa {:columns [:a :b]}
                                     "v11a.parquet" {:columns [:c]}
                                     "v11q" {:columns [:a :b]}}))
  {:error :unknown-column :name :a}
  "identity/absent|alien-copy-silences-own-entry")
# a lone block leaves the arm unnamed, so the where-lane defers
(assert-eq (get (jq/expand-tree (jq/where v11-arm (jq/gt (jq/get :zzz) (jq/lit 1)))
                                {"v11q" {:columns [:a :b]}}) :columns)
           nil
           "identity/absent|lone-block-leaves-arm-unnamed")
# the wall, open in absent mode: a foreign entry under the arm's own
# path spelling DESCRIBES the arm (item 6 records the refutation). A
# FIELD-bearing entry here takes item 2's lane - its writer names no record
# (FIELDLESS IS A VALUE TEST), so the 03fc1ec admission governs it and it
# describes exactly as the fieldless entry does.
(assert-eq (get (jq/expand-tree v11-arm {"v11a.parquet" {:columns [:y :z]}}) :columns)
           [:y :z]
           "identity/absent|foreign-entry-under-own-spelling-describes")

# -- present mode: identity-scoped admission (the three
# conditions as one letter). The own union's member set {a b c} survives an
# alien entry that carries a DIFFERENT list; an alien entry carrying an own
# list still silences that claim (item 3 (iii), the block rule). "The alien
# copy neither adds nor subtracts" is WITHDRAWN: the measured consequence is the block rule.
(def v11-a "v11a.parquet")
(def v11-own {:wa {:columns [:a :b] :writer :wa}
              v11-a {:columns [:c] :writer v11-a}})
(each v11-c [:a :b :c]
  (assert (v11-served? v11-c v11-own)
          (string "identity/present|own-union-serves " v11-c "")))
(assert (not (v11-served? :z v11-own))
        "identity/present|outsider-name-refused")
# The rowless lane's three verdicts, recorded
# beside the cell it closes. Each reads the row the select's input hands
# on through the arm BINDING (key-of/arm-binding-key), never through slot 3
# of the walk tuple, which is nil for an unqualified reference by
# construction. The first is 2103's shape restated as its own name so a
# regression names the mechanism, not just the cell above.
(assert-errz (fn [] (jq/expand-tree (jq/select v11-arm :z) v11-own))
  {:error :unknown-column :name :z}
  "lane|readable-arm-row-refuses-a-name-the-arm-lacks")
# a served name keeps serving on the same row: the ceiling refuses, it never
# narrows
(each v11-c [:a :b :c]
  (assert (v11-served? v11-c v11-own)
          (string "lane|readable-arm-row-serves-what-it-carries " v11-c "")))
# a join's merged row still serves a name either arm carries
(each j-name [:a :s]
  (def cat {:t {:columns [:a :b]} :u {:columns [:a :s]}})
  (assert (nil? (v11-err (fn [] (jq/expand-tree
                                 (jq/select (jq/join (jq/from :t) (jq/from :u) :a :a) j-name)
                                 cat))))
          (string "lane|merged-join-row-still-serves " j-name "")))
# The key slot is NOT the target lane: `:z` is the join's own right key and
# the key lane owns it, so it serves.
(assert (nil? (v11-err (fn [] (jq/expand-tree (jq/select (r6-ch-pq) :z) r6-ch-cat))))
        "lane|join-key-over-an-unreadable-arm-serves")
# An unreadable arm DEFERS for every name - the model's answer, verified:
# rowlessLaneVerdict(l, "open", n, cdesc) == "defer" -> [ok]; the control
# `== "refuse"` -> [violation] (r2d-v3.4-model-qq.md). So an unvouched name
# over an unreadable arm is SERVED (deferred to the engine), and refusing it
# here would be a model violation. The shape is an open question
# instead; this cell records today's law, not the question.
(assert (nil? (v11-err (fn [] (jq/expand-tree (jq/select (r6-ch-pq) :qq) r6-ch-cat))))
        "lane|unreadable-arm-defers-an-unvouched-name")
(assert (v11-served? :a (merge v11-own {"v11q" {:columns [:a :a]}}))
        "identity/present|fieldless-alien-copy-subtracts-nothing")
# The block is CONTENT-edged - an alien entry
# carrying the own entry's list silences it whatever the alien entry's writer
# says. The fieldless copy below is the case; this is the carrying one.
(assert (v11-served? :b (merge v11-own {"v11q" {:columns [:b] :writer "v11q"}}))
        "identity/present|alien-list-still-silences-the-own-claim")
# the carrying-copy cell: the alien entry carries the arm's OWN-path list
# ({c}), which no own entry claims, so the identity admits the {a b} claim
(assert (v11-served? :a (merge v11-own {"v11q" {:columns [:c] :writer "v11q"}}))
        "identity/present|carrying-alien-copy-subtracts-nothing")
# a shared block alone describes nothing: no own-writer entry, the arm defers
(assert-eq (get (jq/expand-tree (jq/where v11-arm (jq/gt (jq/get :zzz) (jq/lit 1)))
                                {"v11q" {:columns [:a :b] :writer "v11q"}}) :columns)
           nil
           "identity/present|shared-block-is-inert")
# identity admission requires the OWN KEY too: an alien-key entry whose
# writer names this record contributes nothing (the present-own rule)
(assert-eq (get (jq/expand-tree (jq/where v11-arm (jq/gt (jq/get :zzz) (jq/lit 1)))
                                {"v11q" {:columns [:y :z] :writer :wa}}) :columns)
           nil
           "identity/present|alien-key-entry-with-own-writer-describes-nothing")

# A writer-bearing entry under the
# arm's OWN path spelling whose writer names NO record is FIELDLESS
# (a value test), so the walk describes the arm. On the unamended walk
# both forms answer ``nil``; on the amended
# walk the plain form serves ``(:y :z)`` and the where form RAISES the
# unknown-column error - the engine's contract, never a nil return.
(each v11-w ["zz.parquet" :zz 42 ""]
  (def v11-div (let [t @{}] (put t "v11a.parquet" {:columns [:y :z] :writer v11-w}) t))
  (assert-eq (get (jq/expand-tree v11-arm v11-div) :columns)
             [:y :z]
             (string "identity/present|fieldless-plain-describes-the-arm writer="
                     (string/format "%q" v11-w) ""))
  (assert-errz (fn [] (jq/expand-tree (jq/where v11-arm (jq/gt (jq/get :zzz) (jq/lit 1)))
                                      v11-div))
    {:error :unknown-column :name :zzz}
    (string "identity/present|fieldless-where-raises-the-unknown-column writer="
            (string/format "%q" v11-w) "")))
# A WRITER-BEARING entry under the arm's own path spelling, whose writer names
# ANOTHER record, contributes nothing: the arm's description is its path
# list alone, never the foreign entry's (measured identically). Written
# with `select` at an undisputed column, the lane where the
# shadow does not reach.
(def v11-wall (let [t @{}] (put t "v11a.parquet" {:columns [:y :z] :writer "v11b.parquet"}) t))
(assert-eq (get (jq/expand-tree (jq/select v11-arm :z) v11-wall) :columns)
           [:z]
           "identity/present|wall-foreign-writer-serves-nothing")

# -- alien
# entries under keys this arm does not answer to change no verdict, while
# the arm's own writer's entry makes the reference decidable (union
# membership - the wider answer the select passthrough already licenses)
(def v11-uj (jq/join (jq/from :t) (jq/from-parquet "/tmp/v11-none.parquet" :alias :vp) :a :a))
(def v11-cr9-own {:t {:columns [:a :b]} :vp {:columns [:a :b] :writer :vp}})
(def v11-cr9-blocks (merge v11-cr9-own
                           {"v11s" {:columns [:a :b] :writer "v11s"}
                            :v11f {:columns [:a :b]}}))
(assert-eq (v11-err (fn [] (jq/expand-tree (jq/where v11-uj (jq/gt (jq/get :zzz) (jq/lit 1)))
                                           v11-cr9-own)))
           (v11-err (fn [] (jq/expand-tree (jq/where v11-uj (jq/gt (jq/get :zzz) (jq/lit 1)))
                                           v11-cr9-blocks)))
           "identity/present|alien-block-presence-flips-no-verdict")
# The outsider reference is answered once both arms are catalogued: the cell
# reads the join's row (:a :b) and refuses :zzz. One arm left uncatalogued and
# the row is open, which serves the name on both engines.
(def v11-cr9-mixed (merge v11-cr9-blocks {:u {:columns [:a]}}))
(assert-errz (fn [] (jq/expand-tree (jq/select (jq/join (jq/from :t) (jq/from :u) :a :a) :zzz)
                                    v11-cr9-mixed))
  {:error :unknown-column :name :zzz}
  "identity/present|described-arm-refuses-the-outsider (witness for the equality cell)")
(assert-eq (get (jq/expand-tree (jq/select v11-uj :a) v11-cr9-blocks) :columns)
           [:a]
           "identity/present|own-writer-entry-serves-its-columns")

# -- P-S1, the union choice (S1 = UNION, ruled): two own entries with
# different column sets serve the de-duplicated union
(def v11-s1 {:wa {:columns [:x :y] :writer :wa}
             "v11a.parquet" {:columns [:y :z] :writer "v11a.parquet"}})
(each v11-c [:x :y :z]
  (assert (v11-served? v11-c v11-s1)
          (string "identity/present|union-serves " v11-c "")))
(assert (not (v11-served? :q v11-s1))
        "identity/present|union-refuses-the-outsider")
# writer spelling invariance: alias- and path-spelling writers name one record
(assert (v11-served? :x (table :wa @{:columns @[:x :y] :writer "v11a.parquet"}
                               "v11a.parquet" @{:columns @[:y :z] :writer :wa}))
        "identity/present|writer-spelling-is-not-the-identity")

(print "RESULT: pass")

