// janet-query intersection rule - Quint specification
// Models the registration/denial machine of specs/api-contract.md
// sections 3, 4, 5 and 7.
//
// State: backend registrations (compatibility matrices as data), the
// committed 8.4 real-query set (each query the set of node types it
// names, per its coverage manifest), and the demotion ledger.
//
// Properties:
//   (a) a shared node is never denied by any registered backend;
//   (b) an extension node is always denied by a non-declaring
//       backend, with the operator and the backend named;
//   (c) denial happens before any render/execute step;
//   (d) the demotion property - a demotion event consistent with
//       the manifest implies zero affected committed queries or a
//       recorded requirements revision;
//   (e) the conflict property - a query never executes when the
//       explicit and the provenance-inferred backend disagree.
//
// Out of scope: renderers, engine behaviour, node semantics, render
// determinism (a string-diff property, proven by snapshot tests).
//
// Verification (two tiers):
//   quint test intersection.qnt
//     - the protocol runs: fast, checks each scripted scenario.
//   quint verify --invariant=inv --max-steps=6 intersection.qnt
//     - the invariant sweep: checks the six properties over every
//       reachable state. The full sweep is minutes, not seconds -
//       increase --max-steps with patience (7 took ~7 minutes).
//     - the invariant has to be checked explicitly: plain `quint
//       verify` checks only the run blocks' local expectations, not
//       the inv conjunction over all reachable states. A green plain
//       verify is NOT the invariant guarantee.

module janetQueryIntersection {

  // Operator universes, abstracted from the classification table.
  // The model checks the machine, not the operator list: SharedV1 is
  // the v1 shared surface, Extensions the per-backend candidates,
  // and every set below is closed under the actions.
  val Backends = Set("duckdb", "rayforce", "third")
  val SharedV1 = Set("from", "where", "join", "group", "select",
                     "order", "limit", "append",
                     "from-parquet", "write-parquet")
  val Extensions = Set("pivot", "window", "asof", "escape")
  val NodeTypes = SharedV1.union(Extensions)
  val QueryIds = Set(1, 2, 3)

  // An execution record: the query, the backend that served it, and
  // the provenance-inferred backend at selection time (equal, per
  // property (e)).
  type ExecRecord = { q: int, backend: str, inferred: str }
  // An expansion denial: query, offending operator, denying backend
  // - the :operator + :backend facts of the error grammar.
  type DenialRecord = { q: int, op: str, backend: str }
  // A demotion ledger event: the operator dropped from the shared
  // set, whether any committed query named it (the manifest check),
  // and whether a requirements revision was recorded.
  type DemotionEvent = { op: str, affected: bool, revised: bool }

  // ---- State ----

  var registered: Set[str]           // registered backend names
  var matrices: str -> Set[str]     // backend -> declared node types (the compatibility matrix)
  var shared: Set[str]              // the current shared set (shrinks on demotion)
  var committed: Set[int]           // the committed 8.4 real-query set
  var queryOps: int -> Set[str]     // per query, the node types it names (its coverage manifest)
  var ledger: Set[DemotionEvent]    // the demotion ledger
  var denials: Set[DenialRecord]
  var executed: Set[ExecRecord]
  var conflicts: Set[int]           // queries refused: :backend-conflict
  var ambiguous: Set[int]           // queries refused: :backend-ambiguous

  action init = all {
    registered' = Set(),
    matrices' = Backends.mapBy(_ => Set()),
    shared' = SharedV1,
    committed' = Set(),
    queryOps' = QueryIds.mapBy(_ => Set()),
    ledger' = Set(),
    denials' = Set(),
    executed' = Set(),
    conflicts' = Set(),
    ambiguous' = Set(),
  }

  // ---- Registration (section 4.1) ----

  // Register a backend declaring the current shared set, optionally
  // plus one extension operator. Matrix well-formedness (known keys,
  // every shared operator declared) is produced by construction and
  // pinned by the matrixWellFormed invariant.
  action registerBackend(b, withExt, ext) =
    all {
      b.in(Backends),
      not(b.in(registered)),
      ext.in(Extensions),
      registered' = registered.union(Set(b)),
      matrices' = matrices.set(b,
        if (withExt) shared.union(Set(ext)) else shared),
      shared' = shared,
      committed' = committed,
      queryOps' = queryOps,
      ledger' = ledger,
      denials' = denials,
      executed' = executed,
      conflicts' = conflicts,
      ambiguous' = ambiguous,
    }

  action register =
    nondet b = Backends.exclude(registered).oneOf();
    nondet withExt = Set(true, false).oneOf();
    nondet ext = Extensions.oneOf();
    registerBackend(b, withExt, ext)

  // A duplicate registration raises the named registration error and
  // changes nothing - the caught raise, modelled as a stutter.
  action registerRejected(b) = all {
    b.in(registered),
    registered' = registered,
    matrices' = matrices,
    shared' = shared,
    committed' = committed,
    queryOps' = queryOps,
    ledger' = ledger,
    denials' = denials,
    executed' = executed,
    conflicts' = conflicts,
    ambiguous' = ambiguous,
  }

  action registerDup =
    nondet b = registered.oneOf();
    registerRejected(b)

  // ---- The committed query set (section 7) ----

  // Commit a query naming the given node types (its coverage
  // manifest row).
  action commitNamed(q, ops) = all {
    q.in(QueryIds),
    not(q.in(committed)),
    ops.subseteq(NodeTypes),
    committed' = committed.union(Set(q)),
    queryOps' = queryOps.set(q, ops),
    registered' = registered,
    matrices' = matrices,
    shared' = shared,
    ledger' = ledger,
    denials' = denials,
    executed' = executed,
    conflicts' = conflicts,
    ambiguous' = ambiguous,
  }

  action commit =
    nondet q = QueryIds.exclude(committed).oneOf();
    nondet base = shared.oneOf();
    nondet extra = NodeTypes.oneOf();
    commitNamed(q, Set(base, extra))

  // ---- Demotion (section 7, the trigger) ----

  // Demote an operator out of the shared set. The trigger: if any
  // committed query names the operator, a requirements revision is
  // recorded in the same event (revised iff affected).
  action demoteOp(op) =
    val affected = committed.filter(q => op.in(queryOps.get(q)))
    all {
      op.in(shared),
      shared' = shared.exclude(Set(op)),
      ledger' = ledger.union(Set({
        op: op,
        affected: affected != Set(),
        revised: affected != Set(),
      })),
      registered' = registered,
      matrices' = matrices,
      committed' = committed,
      queryOps' = queryOps,
      denials' = denials,
      executed' = executed,
      conflicts' = conflicts,
      ambiguous' = ambiguous,
    }

  action demotion =
    nondet op = shared.oneOf();
    demoteOp(op)

  // ---- Execution: selection, expansion, execute (sections 4.3, 4.2) ----

  // One execution attempt over a committed query. The explicit
  // backend and the handle-provenance-inferred backend are resolved
  // first: disagreement raises :backend-conflict (no execution);
  // agreement proceeds to expansion, which either passes (render +
  // execute) or denies an undeclared operator before any render or
  // execute step. The matrix never changes after registration, so a
  // denied (query, backend) pair can never execute later either -
  // property (c) has both the per-step and the across-steps reading.
  action runQuerySelect(q, explicit, inferred) =
    all {
      q.in(committed),
      explicit.in(registered),
      inferred.in(registered),
      any {
        all {
          // Q2 conflict: explicit and inferred disagree - named
          // error, no execution.
          explicit != inferred,
          conflicts' = conflicts.union(Set(q)),
          ambiguous' = ambiguous,
          executed' = executed,
          denials' = denials,
        },
        all {
          // Backends agree and expansion passes: every named
          // operator declared - render and execute.
          explicit == inferred,
          queryOps.get(q).subseteq(matrices.get(explicit)),
          executed' = executed.union(Set({
            q: q, backend: explicit, inferred: inferred,
          })),
          conflicts' = conflicts,
          ambiguous' = ambiguous,
          denials' = denials,
        },
      },
      registered' = registered,
      matrices' = matrices,
      shared' = shared,
      committed' = committed,
      queryOps' = queryOps,
      ledger' = ledger,
    }

  // Expansion denial: an undeclared operator, named with the
  // backend, before any render/execute step. The offending operator
  // is a parameter; runAttempt draws it from the whole universe and
  // the membership guard selects the denial lane (an action-scope
  // nondet per the ownership.qnt pattern - nested nondet inside
  // all-blocks does not bind, and a oneOf over the possibly-empty
  // undeclared set would disable the action in the empty case).
  action runQueryDeny(q, explicit, inferred, op) =
    all {
      q.in(committed),
      explicit.in(registered),
      inferred.in(registered),
      explicit == inferred,
      op.in(queryOps.get(q).exclude(matrices.get(explicit))),
      denials' = denials.union(Set({
        q: q, op: op, backend: explicit,
      })),
      executed' = executed,
      conflicts' = conflicts,
      ambiguous' = ambiguous,
      registered' = registered,
      matrices' = matrices,
      shared' = shared,
      committed' = committed,
      queryOps' = queryOps,
      ledger' = ledger,
    }

  action runAttempt =
    nondet q = committed.oneOf();
    nondet explicit = registered.oneOf();
    nondet inferred = registered.oneOf();
    nondet op = NodeTypes.oneOf();
    any {
      runQuerySelect(q, explicit, inferred),
      runQueryDeny(q, explicit, inferred, op),
    }

  // No explicit backend, no inferable provenance: :backend-ambiguous,
  // no default backend, no execution.
  action runUnbound(q) = all {
    q.in(committed),
    ambiguous' = ambiguous.union(Set(q)),
    conflicts' = conflicts,
    executed' = executed,
    denials' = denials,
    registered' = registered,
    matrices' = matrices,
    shared' = shared,
    committed' = committed,
    queryOps' = queryOps,
    ledger' = ledger,
  }

  action runAmbiguous =
    nondet q = committed.oneOf();
    runUnbound(q)

  // Stutter: the machine can always do nothing (deadlock guard).
  action idle = all {
    registered' = registered,
    matrices' = matrices,
    shared' = shared,
    committed' = committed,
    queryOps' = queryOps,
    ledger' = ledger,
    denials' = denials,
    executed' = executed,
    conflicts' = conflicts,
    ambiguous' = ambiguous,
  }

  action step = any {
    register,
    commit,
    demotion,
    runAttempt,
    runAmbiguous,
    idle,
  }

  // ---- Invariants ----

  // Init conditions (ratified scope (b)): no duplicate registration
  // (set semantics plus the caught-raise stutter above) and matrix
  // well-formedness - every declared entry a known node type, every
  // registered backend declaring the whole current shared set,
  // unregistered backends carrying no matrix.
  val matrixWellFormed = and {
    Backends.forall(b => matrices.get(b).subseteq(NodeTypes)),
    registered.forall(b => shared.subseteq(matrices.get(b))),
    Backends.forall(b => b.in(registered)
      .implies(matrices.get(b) != Set())),
    Backends.forall(b => not(b.in(registered))
      .implies(matrices.get(b) == Set())),
    shared.subseteq(SharedV1),
  }

  // (a) A shared node is never denied by any registered backend.
  // (The shared set only shrinks, so this holds forever after a
  // denial too.)
  val sharedNeverDenied = denials.forall(d => not(d.op.in(shared)))

  // (b) Every denial names a registered backend and an operator that
  // backend does not declare - the :operator + :backend facts.
  val denialNamesBoth = denials.forall(d =>
    and {
      d.backend.in(registered),
      not(d.op.in(matrices.get(d.backend))),
    })

  // (c) Denial happens before any render/execute step: an execution
  // only exists for (query, backend) pairs that passed expansion -
  // every named operator declared - and a denied pair never executes.
  val denialBeforeExecution = and {
    executed.forall(e =>
      queryOps.get(e.q).subseteq(matrices.get(e.backend))),
    executed.forall(e =>
      not(denials.exists(d =>
        d.q == e.q and d.backend == e.backend))),
  }

  // (d) The demotion trigger: a demotion event consistent with the
  // manifest implies zero affected committed queries or a recorded
  // revision - revised exactly when affected.
  val demotionConsistent =
    ledger.forall(e => e.revised == e.affected)

  // (e) The Q2 conflict property: a query never executes when the
  // explicit and the provenance-inferred backend disagree - every
  // execution record carries the agreeing backend.
  val noExecutionOnConflict =
    executed.forall(e => e.backend == e.inferred)

  val inv = and {
    matrixWellFormed,
    sharedNeverDenied,
    denialNamesBoth,
    denialBeforeExecution,
    demotionConsistent,
    noExecutionOnConflict,
  }

  // ---- Protocol tests ----

  // One defquery, every backend, same result surface: a shared-only
  // query executes on two registered backends.
  run sharedQueryBothBackends = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(registerBackend("rayforce", false, "pivot"))
      .then(commitNamed(1, Set("from", "where", "select")))
      .then(runQuerySelect(1, "duckdb", "duckdb"))
      .then(runQuerySelect(1, "rayforce", "rayforce"))
      .expect(inv.and(executed.size() == 2))
  }

  // Extension denial: a pivot node against a backend that does not
  // declare it - named operator + backend, no execution.
  run extensionDeniedNamed = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(commitNamed(1, Set("from", "pivot")))
      .then(runQueryDeny(1, "duckdb", "duckdb", "pivot"))
      .expect(inv
        .and(denials == Set({q: 1, op: "pivot", backend: "duckdb"}))
        .and(executed == Set()))
  }

  // Q2 conflict: explicit duckdb, inferred rayforce - refused, never
  // executed.
  run conflictNeverExecutes = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(registerBackend("rayforce", false, "pivot"))
      .then(commitNamed(1, Set("from")))
      .then(runQuerySelect(1, "duckdb", "rayforce"))
      .expect(inv.and(executed == Set()).and(conflicts == Set(1)))
  }

  // No explicit backend, no inference: :backend-ambiguous, no
  // default, no execution.
  run ambiguousNeverExecutes = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(commitNamed(1, Set("from")))
      .then(runUnbound(1))
      .expect(inv.and(executed == Set()).and(ambiguous == Set(1)))
  }

  // The demotion trigger: a demoted operator named by a committed
  // query carries a recorded revision in the same event.
  run demotionRecordsRevision = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(commitNamed(1, Set("from", "where")))
      .then(demoteOp("where"))
      .expect(inv.and(ledger.exists(e =>
        and { e.op == "where", e.affected, e.revised })))
  }

  // A demotion with zero affected queries records no revision.
  run demotionUnaffectedNeedsNoRevision = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(commitNamed(1, Set("from")))
      .then(demoteOp("where"))
      .expect(inv.and(ledger.exists(e =>
        and { e.op == "where", not(e.affected), not(e.revised) })))
  }

  // Duplicate registration: the named error, nothing changes.
  run duplicateRegisterRejected = {
    init
      .then(registerBackend("duckdb", false, "pivot"))
      .then(registerRejected("duckdb"))
      .expect(inv.and(registered == Set("duckdb")))
  }
}
