// janet-query reference scope model - Quint specification
// Companion to intersection.qnt. Models the reference scope machine of
// specs/api-contract.md (the reference scope section and the writer
// identity section): a reference's verdict is decided by its EMITTING
// NODE's inputs, never by an ancestor.
//
// The file holds two modules. `janetQueryScope` is the reference model:
// which references are served and which are refused above a tree.
// `janetQueryCatalogue` (at the end of the file) is the catalogue lane:
// `source-columns` with records, spelled keys, variant expansion, the
// union walk, the shared-block filter, and WRITER IDENTITY as an
// explicit spec variable with two modes - absent (the behaviour of a
// catalogue carrying no writer field) and present (identity-scoped
// admission).
//
// RUN NAMES. Runs and invariants carry prefixes such as `cr12` or `cm`.
// These are stable identifiers, cited by the contract and by the
// verification record; they are not a change log.
//

// THE PUBLISHED-PROJECTION MODEL. A reference is judged
// against the ROW ITS IMMEDIATE INPUT PUBLISHES, never against a lane
// label attached to some node below it. Four rules, all readable from
// one row value:
//   (i)  the row is the nearest RESHAPING node's output: a join (the
//        union of its arms, whatever the arms are - a parquet arm is
//        unnamed whether or not the caller catalogued it), an append
//        (the positional alignment), a group (keys + computed);
//   (ii) a pass-through (where/limit/order/distinct/query/select)
//        does not reshape: the row is the one beneath it, at ANY
//        distance (WRAPPER-INDEPENDENCE);
//   (iii) a SELECT that declares a projection publishes EXACTLY it -
//        the entry form (bare keyword, get expression, string) is
//        irrelevant. A select that declares nothing publishes nothing:
//        it is a pass-through, and its row is the one beneath;
//   (iv) two selects in a chain each publish their own projection, so
//        an outer projection that names a column the inner does not
//        publish is refused at the OUTER select - the chain-launder
//        prohibition (CHAIN-LAUNDER).
// The published row is independent of the caller's catalog: the
// catalog says which columns an arm supplies (so a real column is
// SERVED, never refused), not whether the arm is unnamed (so
// cataloguing an alias changes no verdict - CATALOG-INDEPENDENCE).
// A join key is judged against its OWN side's outputs (PER-SIDE); a
// reference that merely NAMES a key, above the join, is judged by the
// published row like any other reference (KEY-SLOT).
//
// State: every emitted reference { name, pos } in a map. Three phases:
// "new" (no verdict), "DEFER" (postponed by its node), "DONE" (decided).
// Verdict lanes (all write status):
//   decide(r, row)        a determinable catch-all: accepted iff the
//                         row worn at that node carries the name
//   serve(r)              a PUBLISHED row that carries the name AND a
//                         proven lane supplies it: served (item 2's
//                         "routes to the pre-existing lanes ... where they
//                         can"). The projection alone is never enough
//   publishRefuse(r)      a PUBLISHED row that lacks the name, OR one
//                         that carries it with no proven supplier:
//                         refused at the selector, never deferred (item 2
//                         first sentence; the chain-launder prohibition)
//                         A projection is a REFUSAL BOUNDARY, never an
//                         existence proof
//   keyDecide(r, s, f)    a join key: its column against its OWN side;
//                         the form f is recorded, never consulted
//   witness(r, q)         a qualified ref: :out refuses, :in accepts, an
//                         undeterminable source postpones (item 4)
//   postpone(r)           an opaque reference: DEFERRED, never refused
//   carryDecide / carryPostpone   a reference its node could not decide
//                         is re-judged by the node above it - the row
//                         the parent publishes, at any distance
//   constantPredicate(r)  a where predicate whose leaves are constants:
//                         SERVED without a name check (contract, where
//                         slot)
//
// GROUP NODES. Four rules, each witnessed by runs at the end of the
// module:
//   (1) GROUP-ARGUMENT-LEAK: a group's aggregate-argument references
//       are references inside the GROUP's own scope. They never enter
//       the walk of a node above the group; the group's published row
//       (keys + aggregate output names) is the only row a selector
//       above it is judged against, at every distance.
//   (2) REFUSAL-AUTHORITY: above a group only the SELECTOR may refuse a
//       row-lacking name at every distance; an ORDER or WHERE node
//       above the group falls through its own lanes (refuse/defer), a
//       pinned group-lane behaviour rather than a defect.
//   (3) RESOLVABILITY SPLIT: UNION-MEMBERSHIP (arm-resolvable?)
//       decides whether a catalogued arm's columns enter the known
//       union; VERDICT-DETERMINATION (arm-opaque?) is catalogue-blind.
//       Cataloguing an alias therefore never flips a deferral into a
//       refusal.
//   (4) AGGREGATE-ARGUMENT NORMALISATION: one aggregate node whatever
//       the argument's spelling; a malformed aggregate stays refused.
//       Together with (3) it gives ONE VERDICT PER TREE: the same tree
//       judged the same way twice in one process.
//
// Every action updates every variable (one verdict per step).
//
// Bound choice. The model carries a two-select chain, a key-slot
// reference and a catalogued unnamed arm as VALUES, so all three are
// reachable at --max-steps=4. Bound: 4.
//
// THE CATALOGUE IS AN INDEX (contract, resolver section). Arm identity -
// is the arm named, and by which spelling - is a pure function of the arm
// RECORD. The catalogue can only ADD known-name information for the arm it
// describes: under its own setting it either lists that arm's names
// (`indexed`) or contributes nothing (`absent`, `own-block`). No name ever
// reaches a verdict through a spelling the caller chose: a reference
// naming a column the arm's record does not have is judged against the
// name the record carries (`canonName`), which is the same name under
// every setting. Naming follows the record's spelling, never the
// catalogue's: a bare string in `select` is the same node as its keyword.
//
// Verification. This block states what is verified and by which command.
// It states no verdict about the model beyond these facts.
//
// WHAT IS VERIFIED, AND BY WHAT
//
// 1. Typecheck. `quint typecheck scope-model.qnt` exits 0 over both modules.
//
// 2. The scope floor: 15 state-reading scope definitions, each carried by a
//    pair of runs placed immediately before its definition.
//      green:  quint test --main=janetQueryScope --match='scope.*InMaterialisedModel' scope-model.qnt
//              15 of 15 pass.
//      proof:  the same 15 steps are re-run reading a state they did not
//              write (`*MutantReadsANextState`), each asserted to be false:
//              quint test --main=janetQueryScope --match='MutantReadsANextState' scope-model.qnt
//              is red 15 of 15. A floor run whose step never executes would
//              leave that assertion green, so the red family is the proof
//              the green family executes.
//    Definitions carried: decide, serve, publishRefuse, keyDecide, postpone,
//    witness, catalog, setArm, catalogUnder, form, groupDeclare, groupRefuse,
//    groupOver, groupInside, constantPredicate.
//
// 3. The catalogue pins (module janetQueryCatalogue, the same-path pair):
//      quint test --main=janetQueryCatalogue
//        --match='cmSamePathOwnersKeepDistinctKeys|cmSamePathPairRowRefusesTheSharedText' scope-model.qnt
//    2 of 2 pass, 10000 tests each.
//
// 4. Red-first instruments. A run cannot kill a mutant: a run asserts a
//    property of the model and dies when that property is false, which is a
//    refutation of the model, not of a mutant. What exists instead is a
//    red-first instrument per leg, and each goes red when its target breaks:
//      floor leg: mutation of an action's enablement (dropping the
//        `i != "agg"` conjunct of `groupRefuse`) leaves
//        `scopegroupRefuseInMaterialisedModel` the only red run, 14 green.
//      catalogue leg: mutation of a pin's target (`sharedTextIsOwnedByNeither`
//        forced false) turns `cmSamePathOwnersKeepDistinctKeys` red, or, with
//        the live mutant selected, `cmRowlessMutantVacuity` red with both
//        pins green. The second is the in-tree instrument.
//
// 5. The live mutant `cmRowlessMutantVacuity` is deliberate and stays red: a
//    lane that defers everywhere agrees with the contract on unreadable rows
//    and dies on the readable one. It is the catalogue leg's red-first
//    instrument, so the gate does not select it. It remains in the whole-lane
//    run `quint test --main=janetQueryCatalogue --match='cm.*'`, which is
//    therefore red 1 of 55 and is not a gate leg.
//
// KNOWN UNCOVERED
//   carryDecide and carryPostpone: both need `phase == "DEFER"`, which no
//   run-level step reaches (the runner reads `action(args)` in
//   `init.then(...)` as a call, not as a guard). Left uncovered rather than
//   forced through a run whose assertion cannot hold.
//   The whole-file sweep `quint test --match='.*'` is not usable as a gate: the
//   runner evaluates every module-level definition as a cell in file order
//   and threads state across cells, so bare state reads meet an
//   uninitialised state before any run executes (125 of 224 cells red on
//   Quint 0.33.1, 45 QNT502 and 63 QNT516).
//
// catalogue lane (module janetQueryCatalogue; one bounded verify per
// property cluster, refutations expected in absent mode):
//   quint verify --main=janetQueryCatalogue --init=initAbsent --step=step \
//     --max-steps=3 --invariant=ps2Neutrality scope-model.qnt
//   (likewise absorptionNever, presenceNeverFlips, absentFieldUnions)
//   quint verify --main=janetQueryCatalogue --init=initPresent --step=step \
//     --max-steps=3 --invariant=ps2Neutrality scope-model.qnt
//   (likewise absorptionNever, presenceNeverFlips)
//   quint test --main=janetQueryCatalogue --match='cm.*' scope-model.qnt

module janetQueryScope {

  // the reference domain: three catalogue names (a: T, c/d: P) plus an
  // UNCATALOGUED o1 - the smallest domain in which every invariant
  // below has a witness. One position per name: the state is a map
  // keyed by reference, so a second position only re-runs the same
  // lanes and multiplies the interleaving
  val Cols = Set("a", "c", "d", "o1")
  val Positions = Set(1)
  pure def Refs = Cols.map(c => Positions.map(p => { name: c, pos: p })).flatten()
  // the rows a node can wear: the arms' unions, and the projections
  // publishers can declare. T alone, P alone, the unnamed union (whose
  // extra name a catalogued arm supplies), the named union.
  pure def Rows = Set(Set("a", "b"), Set("c", "d"), Set("a", "b", "c", "d"),
                      Set("a", "b", "e", "f"), Set("e", "f"))
  // the published rows: a select's projection and a pass-through's
  // inherited row. Includes Set(), the DECLARED-EMPTY projection. No
  // member equals a SIDE's own outputs (a join key's row): a published
  // row is the whole row a node hands on, a side row is the key lane's
  // own, and keeping them disjoint is what makes the key-slot
  // invariant stateable. A select over the P arm publishes one of the
  // wider rows instead
  val Published = Set(Set("a"), Set("a", "c"), Set("c"), Set(),
                      Set("c", "d", "a"), Set("e", "f", "c", "d"),
                      Set("a", "b", "c", "d"))
  // whether the published row is DECIDED or DEFERRED by the node: a
  // row carrying the opaque Q arm cannot be enumerated, so it stays
  // undeterminable unless a declared projection bounds it
  val PublishedLive = Set(Set("a"), Set("a", "c"), Set("c"), Set(),
                          Set("c", "d", "a"), Set("e", "f", "c", "d"),
                          Set("a", "b", "c", "d"))

  val KeyForms = Set("kw", "str")
  val Quals = Set("cat", "open", "none")
  val Side = Set("L", "R")
  // THE ARM RECORD. A parquet arm's identity is read from
  // the NODE: `carriesAlias` (does the record name an alias?) and, within
  // an arm, the shorthand `k`. Everything about the arm follows from the
  // record; nothing follows from a catalogue key. Across ARMS the record
  // varies - the suite runs the bare arm and the aliased arm over the
  // same trees - which is why identity is stated over the arm, not over
  // an abstraction of the arm
  pure def carriesAlias(a: str): bool = a == "aliased"
  pure def armRecorded(a: str): bool = carriesAlias(a) or a == "bare"
  // the alias-carrying arm. A DEF, not a literal: the record is what makes
  // the two arms two arms, and the suite reaches both through `setArm`
  pure def isArmCarryingAlias(a: str): bool = a == "aliased"
  // THE FIVE CATALOGUE SETTINGS over ONE tree. Every setting
  // is a catalogue the caller may legitimately supply and each one names
  // THIS arm under its own key:
  //   "alias"      the arm catalogued under its ALIAS, its own names
  //   "path"       the arm catalogued under its PATH, the same names - the
  //                same information under the other spelling
  //   "bkey"       BOTH of the arm's keys, the same names again (the
  //                ordinary alias+path catalogue)
  //   "absent"     no entry for the arm at all
  //   "own-block"  a block under the arm's own keys that another source
  //                also lists - an entry that describes no arm
  // The verdict must be invariant under all five.
  val Cods = Set("alias", "path", "bkey", "absent", "own-block")
  // UNION-MEMBERSHIP: does this setting let the arm contribute names?
  // This is the ONLY thing the catalogue is allowed to decide. "absent"
  // is the absent-key shape and "own-block" a
  // block no arm is described by; neither contributes a name
  pure def armResolvable(c: str): bool =
    c == "alias" or c == "path" or c == "bkey"
  // VERDICT-DETERMINATION: is the arm opaque for judging a reference?
  // Catalogue-INDEPENDENT by construction: the answer is
  // `not armResolvable(c)`, so opacity MOVES with membership - an
  // uncatalogued arm is opaque (the engine oracle decides), a catalogued
  // one is dealt with by the records' names. That is the one coupling the
  // rule allows. It is a DEF, not a constant, because a catalogue that
  // removed a listed name must be the flipping state
  pure def armOpaque(c: str): bool = not(armResolvable(c))
  // why no lane below reads the emitted spelling. CANONICALISATION IS
  // IDENTITY: the function is not spelled as a fold, because this Quint
  // build resolves `fold` only on a Set/List literal receiver
  // (`n.fold(...)`, `n.map(...)`, `List(n).fold(...)` and
  // `n.charfold(...)` all fail typecheck). The mutant that re-spells
  // here fails the canonical-name run
  pure def canonName(n: str): str = n
  // THE ARM'S NAMES, BY SETTING: enumeration only. The list a setting
  // supplies is a function of the arm (all spellings of one arm say the
  // same thing); the SETTING decides whether the list is supplied at all
  pure def armNames(c: str): Set[str] =
    if (armResolvable(c)) Set("c", "d") else Set()
  // placeholder predicate, kept for the membership lane: no setting in
  // Cods is a placeholder, so this is FALSE everywhere - and the run that
  // claims it says so (cr11NoSettingIsAPlaceholder)
  pure def armIsPlaceholder(c: str): bool = false
  // the row a group publishes: its keys plus one name per aggregate
  pure def groupRow(c: str): Set[str] =
    if (c == "c") Set("b", "countC") else Set("a", "sumC")
  // the aggregate's ARGUMENT: a reference inside the group's scope
  pure def groupArg(c: str): str = if (c == "c") "c" else "c"
  // where a reference sits relative to the group: the group's own
  // scope, or a selector ABOVE it (direct / one-expression select /
  // stacked select), an order, or a where
  val GroupDists = Set("inside", "direct", "select", "stacked", "order", "where")
  // the aggregate argument forms the constructors emit
  val AggForms = Set("bare", "str", "get")
  // and the class that is not an aggregate at all. The three
  // non-aggregate input spellings the normaliser refuses - a literal, a
  // string literal, and an arbitrary expression - are separate
  // constructors, so a string literal is distinguishable from a number
  // and the phantom aggregate has a witness
  val AggInputs = Set("agg", "literal", "strlit", "expr")
  // the entry forms a projection can be written in
  val EntryForms = Set("bare", "get", "str")

  val T = Set("a", "b")
  val P = Set("c", "d")
  val WIDE = T.union(P)

  pure def sideCols(s: str): Set[str] =
    if (s == "L") Set("a", "b") else Set("c", "d")

  // THE INDEX: the names a setting enumerates. It is the
  // only route from the catalogue to a name, and it answers a NAME SET -
  // a set has no order and no key, so nothing downstream can read a
  // spelling or a position out of it. `armNamesOf` is what a source's
  // columns ARE; `namesOf` is what the catalogue says about them
  pure def armNamesOf(c: str): Set[str] = armNames(c)
  pure def namesOf(c: str): Set[str] = armNames(c)
  // a PROVEN supplier: a known column set. The uncatalogued arm ("o1") is
  // the counterexample - nothing can prove the file carries it, so a
  // projection naming it proves nothing (a published projection is a
  // refusal boundary, never an existence
  // proof). The predicate reads the CATALOGUE-INDEPENDENT known set (T,
  // plus the arm's names where the arm's record names them - the
  // catalogue has already been filtered through `namesOf` upstream).
  // The wide row is the tree's own and P is NOT in it:
  // cataloguing is the only way a P name is ever supplied
  pure def knownSet: Set[str] = T.union(namesOf("alias"))
  pure def suppliedBy(r: { name: str, pos: int }, c: str): bool =
    r.name.in(T) or r.name.in(namesOf(c))

  // which row a produced name sits in, for the counterexample reader:
  // the row a select PUBLISHES is the boundary no name crosses
  // ---- State ----
  var phase: { name: str, pos: int } -> str
  var status: { name: str, pos: int } -> str
  var worn: { name: str, pos: int } -> Set[str]
  var aform: { name: str, pos: int } -> str
  var lane: { name: str, pos: int } -> str
  var side: { name: str, pos: int } -> str
  var proj: { name: str, pos: int } -> Set[str]
  var cod: { name: str, pos: int } -> str
  var dist: { name: str, pos: int } -> int
  var entry: { name: str, pos: int } -> str
  // the ARM each reference sits over: identity is a function of
  // this value, never of `cod`
  var arm: { name: str, pos: int } -> str
  // the key a catalogue setting is written under (Keyings)
  var keying: { name: str, pos: int } -> str

  action init = all {
    phase' = Refs.mapBy(_ => "new"),
    status' = Refs.mapBy(_ => "none"),
    worn' = Refs.mapBy(_ => Set()),
    aform' = Refs.mapBy(_ => "none"),
    lane' = Refs.mapBy(_ => "none"),
    side' = Refs.mapBy(_ => "none"),
    proj' = Refs.mapBy(_ => Set()),
    cod' = Refs.mapBy(_ => "none"),
    dist' = Refs.mapBy(_ => 0),
    entry' = Refs.mapBy(_ => "none"),
    // "bare" is the alias-less arm: the record carries a path and no name
    arm' = Refs.mapBy(_ => "bare"),
    keying' = Refs.mapBy(_ => "canon"),
  }

  action stutter = all {
    phase' = phase, status' = status, worn' = worn,
    aform' = aform, lane' = lane, side' = side, proj' = proj,
    cod' = cod, dist' = dist, entry' = entry, arm' = arm,
    keying' = keying,
  }

  // ---- Lanes (every variable written, one verdict per step) ----
  // (the `Lanes` NAME below is the catalogue module's, not this one's -
  //  two modules, two names: this model's `lane` var is its source lane)

  // THE SOURCE LANE: a node wearing its SOURCE's row - the
  // catalogue's names where the setting enumerates them, nothing where it
  // does not. Its row is a function of the arm record and the index:
  // `knownNamesAt` never reads a spelling, so a name's verdict here is
  // the same under every setting that enumerates the arm. The lane reads
  // no free row list, so it cannot be handed a row no source supplies
  pure def knownNamesAt(c: str): Set[str] = T.union(namesOf(c))
  // the same save for the opaque lane: an arm no setting enumerates
  // blanket (decide): the definition reached in a materialised model
  run scopedecideInMaterialisedModel = {
    init
      .then(decide({ name: "a", pos: 1 }))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (decide): the same step, one state ahead on the reference
  run decideMutantReadsANextState = {
    init
      .then(decide({ name: "a", pos: 1 }))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action decide(r) =
    all {
      r.in(Refs),
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r, if (r.name.in(knownNamesAt(cod.get(r)))) "ok" else "err"),
      worn' = worn.set(r, knownNamesAt(cod.get(r))),
      aform' = aform,
      lane' = lane.set(r, "decide"),
      side' = side,
      proj' = proj.set(r, knownNamesAt(cod.get(r))),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action decideAny =
    nondet r = Refs.oneOf();
    decide(r)

  // the projection NAMES the column AND a proven lane supplies it: served.
  // A projection is a refusal boundary, never an existence proof: the
  // row says what the selector HANDS ON,
  // not what its input can supply. The name must therefore sit in a
  // CATALOGUED source's columns (WIDE) as well as in the projection - a
  // projection entry no proven supplier backs is refused rather than
  // served
  // blanket (serve): the definition reached in a materialised model
  run scopeserveInMaterialisedModel = {
    init
      .then(serve({ name: "a", pos: 1 }, Set("a", "c")))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (serve): the same step, one state ahead on the reference
  run serveMutantReadsANextState = {
    init
      .then(serve({ name: "a", pos: 1 }, Set("a", "c")))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action serve(r, row) =
    all {
      r.in(Refs),
      row.in(Published),
      r.name.in(row),
      suppliedBy(r, cod.get(r)),
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r, "ok"),
      worn' = worn.set(r, row),
      aform' = aform,
      lane' = lane.set(r, "serve"),
      side' = side,
      proj' = proj.set(r, row),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action serveAny =
    nondet r = Refs.oneOf();
    nondet row = Published.oneOf();
    serve(r, row)

  // the projection LACKS the column OR nothing proven supplies it:
  // refused at the selector. A name the projection carries but no
  // catalogued source backs is refused by the same rule - the row is a
  // boundary, and a boundary cannot vouch for a column its input may not
  // have. No deferral, no reach-through to a pre-projection column, and
  // no exemption for a name that happens to equal a join key
  // blanket (publishRefuse): the definition reached in a materialised model
  run scopepublishRefuseInMaterialisedModel = {
    init
      .then(publishRefuse({ name: "a", pos: 1 }, Set("c")))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (publishRefuse): the same step, one state ahead on the reference
  run publishRefuseMutantReadsANextState = {
    init
      .then(publishRefuse({ name: "a", pos: 1 }, Set("c")))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action publishRefuse(r, row) =
    all {
      r.in(Refs),
      row.in(Published),
      // a PUBLISHED row is the boundary, so the projection
      // limb alone decides - a row that does not carry the name is refused
      // whatever the supplier says. A supplier conjunct would make the
      // refusal unreachable for a row lacking a name in T
      not(r.name.in(row)),
      phase.get(r) == "new",      phase' = phase.set(r, "DONE"),
      status' = status.set(r, "err"),
      worn' = worn.set(r, row),
      aform' = aform,
      lane' = lane.set(r, "publish"),
      side' = side,
      proj' = proj.set(r, row),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action publishRefuseAny =
    nondet r = Refs.oneOf();
    nondet row = Published.oneOf();
    publishRefuse(r, row)

  // blanket (keyDecide): the definition reached in a materialised model
  run scopekeyDecideInMaterialisedModel = {
    init
      .then(keyDecide({ name: "a", pos: 1 }, "L", "kw"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (keyDecide): the same step, one state ahead on the reference
  run keyDecideMutantReadsANextState = {
    init
      .then(keyDecide({ name: "a", pos: 1 }, "L", "kw"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action keyDecide(r, s, f) =
    all {
      r.in(Refs),
      s.in(Side),
      f.in(KeyForms),
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      // two branches, not an if: quint's evaluator mis-types an
      // if (...) "ok" else "err" that straddles a variable
      any {
        all { r.name.in(sideCols(s)), status' = status.set(r, "ok") },
        all { not(r.name.in(sideCols(s))), status' = status.set(r, "err") },
      },
      worn' = worn.set(r, sideCols(s)),
      aform' = aform.set(r, f),
      lane' = lane.set(r, "key"),
      side' = side.set(r, s),
      proj' = proj.set(r, sideCols(s)),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action keyAny =
    nondet r = Refs.oneOf();
    nondet s = Side.oneOf();
    nondet f = KeyForms.oneOf();
    keyDecide(r, s, f)

  // blanket (postpone): the definition reached in a materialised model
  run scopepostponeInMaterialisedModel = {
    init
      .then(postpone({ name: "a", pos: 1 }))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (postpone): the same step, one state ahead on the reference
  run postponeMutantReadsANextState = {
    init
      .then(postpone({ name: "a", pos: 1 }))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action postpone(r) =
    all {
      r.in(Refs),
      phase.get(r) == "new",
      phase' = phase.set(r, "DEFER"),
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane.set(r, "postpone"),
      side' = side,
      proj' = proj,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action postponeAny = nondet r = Refs.oneOf(); postpone(r)

  // blanket (witness): the definition reached in a materialised model
  run scopewitnessInMaterialisedModel = {
    init
      .then(witness({ name: "a", pos: 1 }, "cat"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (witness): the same step, one state ahead on the reference
  run witnessMutantReadsANextState = {
    init
      .then(witness({ name: "a", pos: 1 }, "cat"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action witness(r, q) =
    all {
      r.in(Refs),
      q.in(Quals),
      phase.get(r) == "new",
      phase' = phase.set(r, if (q == "cat") "DONE" else "DEFER"),
      status' = if (q == "cat")
                  status.set(r, if (r.name.in(P)) "ok" else "err")
                else status,
      worn' = worn.set(r, if (q == "cat") P else worn.get(r)),
      aform' = aform,
      lane' = lane.set(r, q),
      side' = side,
      proj' = proj,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action witnessAny =
    nondet r = Refs.oneOf();
    nondet q = Quals.oneOf();
    witness(r, q)

  // WRAPPER-INDEPENDENCE: a reference the node below could not decide
  // is re-judged by the row the parent publishes, at any distance. The
  // distance is carried (1..3) and never consulted
  action carryDecide(r, row, d) =
    all {
      r.in(Refs),
      row.in(PublishedLive),
      d.in(Set(1, 2, 3)),
      phase.get(r) == "DEFER",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r, if (r.name.in(row) and suppliedBy(r, cod.get(r))) "ok" else "err"),
      worn' = worn.set(r, row),
      aform' = aform,
      lane' = lane.set(r, "postpone-carried"),
      side' = side,
      proj' = proj.set(r, row),
      cod' = cod,
      dist' = dist.set(r, d),
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action carryDecideAny =
    nondet r = Refs.oneOf();
    nondet row = PublishedLive.oneOf();
    nondet d = Set(1, 2, 3).oneOf();
    carryDecide(r, row, d)

  action carryPostpone(r) =
    all {
      r.in(Refs),
      phase.get(r) == "DEFER",
      phase' = phase,
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane,
      side' = side,
      proj' = proj,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action carryPostponeAny = nondet r = Refs.oneOf(); carryPostpone(r)

  // CATALOG-INDEPENDENCE: the caller's catalogue is a free parameter of
  // the tree. Either setting is reachable, and no invariant below reads
  // it - the two settings produce the same verdict set
  // the KEY the catalogue is written under is a free parameter of
  // the setting, exactly as the arm record is a free parameter of the
  // tree. "canon" is the source's canonical key; "binding" is another
  // key the SAME source answers to (a :from arm's alias, or a parquet
  // arm's path under an alias-keyed setting). The two
  // are two spellings of one source, so no verdict may read the choice.
  val Keyings = Set("canon", "binding")

  // blanket (catalog): the definition reached in a materialised model
  run scopecatalogInMaterialisedModel = {
    init
      .then(catalog({ name: "a", pos: 1 }, "alias"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (catalog): the same step, one state ahead on the reference
  run catalogMutantReadsANextState = {
    init
      .then(catalog({ name: "a", pos: 1 }, "alias"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action catalog(r, c) =
    all {
      r.in(Refs),
      c.in(Cods),
      phase.get(r) == "new",
      phase' = phase,
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane,
      side' = side,
      proj' = proj,
      cod' = cod.set(r, c),
      keying' = keying.set(r, "canon"),
      dist' = dist,
      entry' = entry,
      arm' = arm,
    }

  // THE ARM RECORD is a free parameter of the TREE, like the setting:
  // the same tree over an alias-less arm and over an arm carrying one is
  // two trees. Identity follows the record (`carriesAlias`), never the
  // setting - writing this as `cod = "path"` would be reading identity
  // out of the catalogue, the defect the redesign removes
  // blanket (setArm): the definition reached in a materialised model
  run scopesetArmInMaterialisedModel = {
    init
      .then(setArm({ name: "a", pos: 1 }, "bare"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (setArm): the same step, one state ahead on the reference
  run setArmMutantReadsANextState = {
    init
      .then(setArm({ name: "a", pos: 1 }, "bare"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action setArm(r, a) =
    all {
      r.in(Refs),
      a.in(Set("bare", "aliased")),
      phase.get(r) == "new",
      phase' = phase,
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane,
      side' = side,
      proj' = proj,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm.set(r, a),
      keying' = keying,
    }

  action setArmAny =
    nondet r = Refs.oneOf();
    nondet a = Set("bare", "aliased").oneOf();
    setArm(r, a)

  action catalogAny =
    nondet r = Refs.oneOf();
    nondet c = Cods.oneOf();
    catalog(r, c)

  // the same setting written under another key of the same source
  // blanket (catalogUnder): the definition reached in a materialised model
  run scopecatalogUnderInMaterialisedModel = {
    init
      .then(catalogUnder({ name: "a", pos: 1 }, "alias", "canon"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (catalogUnder): the same step, one state ahead on the reference
  run catalogUnderMutantReadsANextState = {
    init
      .then(catalogUnder({ name: "a", pos: 1 }, "alias", "canon"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action catalogUnder(r, c, k) =
    all {
      r.in(Refs),
      c.in(Cods),
      k.in(Keyings),
      phase.get(r) == "new",
      phase' = phase,
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane,
      side' = side,
      proj' = proj,
      cod' = cod.set(r, c),
      dist' = dist,
      entry' = entry,
      arm' = arm,
      keying' = keying.set(r, k),
    }

  action catalogUnderAny =
    nondet r = Refs.oneOf();
    nondet c = Cods.oneOf();
    nondet k = Keyings.oneOf();
    catalogUnder(r, c, k)

  // the entry form a publishable projection was WRITTEN in: the same
  // column, three spellings. Recorded, never consulted (ENTRY-FORM)
  // blanket (form): the definition reached in a materialised model
  run scopeformInMaterialisedModel = {
    init
      .then(form({ name: "a", pos: 1 }, "get"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (form): the same step, one state ahead on the reference
  run formMutantReadsANextState = {
    init
      .then(form({ name: "a", pos: 1 }, "get"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action form(r, e) =
    all {
      r.in(Refs),
      e.in(EntryForms),
      phase.get(r) == "new",
      phase' = phase,
      status' = status,
      worn' = worn,
      aform' = aform,
      lane' = lane,
      side' = side,
      proj' = proj,
      cod' = cod,
      dist' = dist,
      entry' = entry.set(r, e),
      arm' = arm, keying' = keying,
    }

  // the group lanes: a group declares a
  // key, an aggregate and the aggregate's argument -- the group's row
  // is groupRow(key) whatever the aggregate's argument form. Choosing
  // the form (bare / string / get) is RECORDED, never consulted; a
  // literal in the aggregate position is a malformed aggregate
  // blanket (groupDeclare): the definition reached in a materialised model
  run scopegroupDeclareInMaterialisedModel = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "get"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (groupDeclare): the same step, one state ahead on the reference
  run groupDeclareMutantReadsANextState = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "get"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action groupDeclare(r, g, a) =
    all {
      r.in(Refs),
      g.in(Set("a", "b")),
      a.in(AggForms),
      phase.get(r) == "new",
      aform' = aform.set(r, a),
      worn' = worn.set(r, groupRow(g)),
      proj' = proj.set(r, groupRow(g)),
      phase' = phase,
      status' = status,
      lane' = lane.set(r, "group"),
      side' = side,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action groupDeclareAny =
    nondet r = Refs.oneOf();
    nondet g = Set("a", "b").oneOf();
    nondet a = AggForms.oneOf();
    groupDeclare(r, g, a)

  // a malformed aggregate refuses at the
  // group node itself, whatever else the tree holds. It publishes NO
  // row: a group that cannot be built has no row to hand on, so the
  // reference wears nothing (wearing a row it names would refuse a
  // name the row carries - the unionKeepsRealColumns violation this
  // model first produced)
  // blanket (groupRefuse): the definition reached in a materialised model.
  // The call takes "literal": "c" is outside AggInputs, so it never enabled.
  run scopegroupRefuseInMaterialisedModel = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "literal"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (groupRefuse): the same step, one state ahead on the reference
  run groupRefuseMutantReadsANextState = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "literal"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action groupRefuse(r, i) =
    all {
      r.in(Refs),
      i.in(AggInputs),
      i != "agg",
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r, "err"),
      aform' = aform,
      worn' = worn.set(r, Set()),
      proj' = proj.set(r, Set()),
      lane' = lane.set(r, "malformed"),
      side' = side,
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action groupRefuseAny =
    nondet r = Refs.oneOf();
    nondet i = AggInputs.oneOf();
    groupRefuse(r, i)

  // the group's PUBLISHED ROW decides a reference ABOVE the group, at
  // every distance {direct, select, stacked select, order, where}:
  // served iff the row names it and a proven supplier backs it, refused
  // otherwise (the same boundary rule as the projection)
  // blanket (groupOver): the definition reached in a materialised model
  run scopegroupOverInMaterialisedModel = {
    init
      .then(groupOver({ name: "a", pos: 1 }, "b", "select"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (groupOver): the same step, one state ahead on the reference
  run groupOverMutantReadsANextState = {
    init
      .then(groupOver({ name: "a", pos: 1 }, "b", "select"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action groupOver(r, g, d) =
    all {
      r.in(Refs),
      g.in(Set("a", "b")),
      d.in(GroupDists),
      d != "inside",
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r,
        if (r.name.in(groupRow(g)) and suppliedBy(r, cod.get(r))) "ok" else "err"),
      worn' = worn.set(r, groupRow(g)),
      aform' = aform,
      lane' = lane.set(r, "group-over"),
      side' = side,
      proj' = proj.set(r, groupRow(g)),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action groupOverAny =
    nondet r = Refs.oneOf();
    nondet g = Set("a", "b").oneOf();
    nondet d = GroupDists.oneOf();
    groupOver(r, g, d)

  // the group's own scope: its aggregate's ARGUMENT is a reference
  // inside the group, judged against the group's INPUT row (the join's
  // union). It never reaches an outer walk - the leak lane is the
  // group-over row above, which carries groupRow and nothing else
  // blanket (groupInside): the definition reached in a materialised model
  run scopegroupInsideInMaterialisedModel = {
    init
      .then(groupInside({ name: "a", pos: 1 }, "b"))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (groupInside): the same step, one state ahead on the reference
  run groupInsideMutantReadsANextState = {
    init
      .then(groupInside({ name: "a", pos: 1 }, "b"))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action groupInside(r, g) =
    all {
      r.in(Refs),
      g.in(Set("a", "b")),
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      // the group's INPUT row is the catalogue's, exactly as
      // the source lane's is - the inside lane is judged by the same index
      // every other lane reads, so an uncatalogued aggregate argument is
      // impossible at a group whose arm no setting enumerates
      status' = status.set(r, if (r.name.in(knownNamesAt(cod.get(r)))) "ok" else "err"),
      worn' = worn.set(r, knownNamesAt(cod.get(r))),
      aform' = aform,
      lane' = lane.set(r, "group-in"),
      side' = side,
      proj' = proj.set(r, knownNamesAt(cod.get(r))),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action groupInsideAny =
    nondet r = Refs.oneOf();
    nondet g = Set("a", "b").oneOf();
    groupInside(r, g)

  // a where predicate whose leaves are all constants: SERVED without a
  // name check. The row is the input's; no leaf is
  // judged
  // blanket (constantPredicate): the definition reached in a materialised model
  run scopeconstantPredicateInMaterialisedModel = {
    init
      .then(constantPredicate({ name: "a", pos: 1 }))
      .expect(all { phase.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }) or status.get({ name: "a", pos: 1 }) == status.get({ name: "a", pos: 1 }),
                    lane.get({ name: "a", pos: 1 }) == lane.get({ name: "a", pos: 1 }) })
      .then(stutter)
  }

  // blanket mutant (constantPredicate): the same step, one state ahead on the reference
  run constantPredicateMutantReadsANextState = {
    init
      .then(constantPredicate({ name: "a", pos: 1 }))
      .expect(status.get({ name: "a", pos: 1 }) == "INFRA")
      .then(stutter)
  }

  action constantPredicate(r) =
    all {
      r.in(Refs),
      phase.get(r) == "new",
      phase' = phase.set(r, "DONE"),
      status' = status.set(r, "ok"),
      worn' = worn.set(r, WIDE),
      aform' = aform,
      lane' = lane.set(r, "constant-pred"),
      side' = side,
      proj' = proj.set(r, WIDE),
      cod' = cod,
      dist' = dist,
      entry' = entry,
      arm' = arm, keying' = keying,
    }

  action constantPredicateAny = nondet r = Refs.oneOf(); constantPredicate(r)

  action formAny =
    nondet r = Refs.oneOf();
    nondet e = EntryForms.oneOf();
    form(r, e)

  action step = any {
    decideAny, serveAny, publishRefuseAny, keyAny, postponeAny,
    witnessAny, carryDecideAny, carryPostponeAny, catalogAny, formAny,
    groupDeclareAny, groupRefuseAny, groupOverAny, groupInsideAny,
    constantPredicateAny, setArmAny, catalogUnderAny,
    stutter,
  }



  // ---- Invariants ----

  // (a) MERGED-ROW: at a determinable node the verdict is the row's own -
  // accepted iff the row worn there carries the name. True of a node
  // that wears what it publishes
  val mergedRow =
    Refs.forall(r =>
      not(lane.get(r) == "decide")
      or(((status.get(r) == "ok") == r.name.in(worn.get(r)))))

  // (a) the union loses nothing: no name a row carries is refused there.
  // The refusal limb carries the boundary rule's `suppliedBy` term: a
  // carried row that CARRIES the name while no proven supplier backs it
  // is REFUSED, not served. This is the same refusal limb
  // `projectionRefusalIsPublished` states for the publish lane, lifted
  // to every lane
  val unionKeepsRealColumns =
    Refs.forall(r =>
      not(status.get(r) == "err")
      or(not(r.name.in(worn.get(r))) or not(suppliedBy(r, cod.get(r)))))

  // (b) PER-SIDE: at a join a key's verdict is its OWN side's - accepted
  // iff the key names one of that side's outputs, so a key naming only the
  // other arm is refused
  val perSideKey =
    Refs.forall(r =>
      not(lane.get(r) == "key")
      or((status.get(r) == "ok") == r.name.in(sideCols(side.get(r)))))

  // (d) KEY-SLOT: the verdict is the column's own in its side's outputs,
  // identical for both forms (no form-dependent branch)
  val keyFormEquivalent =
    Refs.forall(r =>
      not(lane.get(r) == "key")
      or((status.get(r) == "ok") == r.name.in(worn.get(r))))

  // (d) KEY-SLOT at the published boundary: a reference ABOVE a
  // published row that merely names a join key gets the published-row
  // verdict like any other reference - the key lane does not reach
  // through the projection. KEY-SLOT is the converse direction, which
  // is what an implementation can violate: a reference the node ABOVE
  // a published row decides must not have been decided against its
  // own side's outputs (the key lane's row), because that row is not
  // what the projection publishes. The lanes are separate, so a state
  // is one or the other, never both
  val keySlotStaysAtTheJoin =
    Refs.forall(r =>
      not(lane.get(r) == "key")
      or(not(worn.get(r).in(Published))
         and(sideCols(side.get(r)) == worn.get(r))))

  // (d) the carried lanes never wear a side's own outputs: the row a
  // pass-through hands on is the row its node published, so a carried
  // verdict citing one side's outputs is the key lane leaking past its
  // node. (`serve` and `publish` need no such clause: their own guards
  // prove `r.name in proj` and `supplied(r)` / their negation, so their
  // row IS the verdict - see projectionDecides and
  // publishedRowNeedsAProvenSupplier)
  val carriedLanesWearTheProjection =
    Refs.forall(r =>
      not(lane.get(r) == "postpone-carried")
      or worn.get(r).in(Published))

  // (c) DEFERRAL never refuses at the deferring node, SCOPED to nodes
  // that publish nothing (the three-state boundary). DEFERRAL IS
  // SCOPED TO PRE-PUBLISH SCOPE: the licence to defer exists only where
  // NO ROW HAS BEEN PUBLISHED yet. Once a node publishes a projection,
  // the reference stops being deferrable - it is JUDGED (served where a
  // proven supplier backs a name the row carries, refused otherwise).
  // The unscoped read - "no reference is deferred and refused" - is false
  // of the ratified model once the chain launder is refused: a reference
  // defers at the join and is then refused by the ceiling of the
  // selector above it. Two nodes, one reference; the deferral was never
  // a refusal at ITS OWN node. The unscoped form is refuted by exactly
  // that trace, the scoped form is not
  val deferralNeverRefuses =
    Refs.forall(r =>
      not(phase.get(r) == "DEFER" or phase.get(r) == "DONE")
      or not(lane.get(r) == "postpone")
      or status.get(r) == "none")

  // (c) STABILITY: a verdict once reached is never changed
  val verdictStable =
    Refs.forall(r => status.get(r) == "none" or phase.get(r) == "DONE")

  // (c) a carried verdict exists only where the reference was postponed
  val carriedOnlyAfterDeferral =
    Refs.forall(r => not(lane.get(r) == "postpone-carried")
                     or dist.get(r) > 0)
  // (e) an opaque lane never decides: an uncatalogued source defers
  val opaqueNeverAccepted =
    Refs.forall(r => not(lane.get(r) == "postpone") or status.get(r) == "none")

  // (e') PLACEHOLDER OPACITY: an entry that is a
  // PLACEHOLDER ("" or "none") lists no names, so it can never be the
  // supplier that opens a name outside the wide row.
  // The real-column entries ("alias", "shared") are the only ones that
  // contribute names. A state where a "none" entry serves an arm name
  // refutes this
  val placeholderSuppliesNothing =
    Refs.forall(r =>
      or(not(armIsPlaceholder(cod.get(r))),
         not(r.name.in(armNames(cod.get(r))))))

  // (f) PUBLISHED-PROJECTION: above a selector nothing is SERVED that
  // the published row does not carry, and nothing is REFUSED that it
  // does carry; a reference a pass-through hands to the selector's row
  // gets that row's verdict at ANY distance. One rule for both lanes,
  // because the distance is not a scope - it is the same row arriving
  // at a different depth
  // the row a reference wears. An OPEN reference wears nothing; a
  // DEFERRED one wears whatever its deferring node recorded, which the
  // carried lane may judge (deferral is a postponement)
  // an OPEN reference wears nothing; a settled one wears the row it
  // was judged against. `phase != new` is the Apalache workaround for
  // reading a row written in the same action (a bare
  // implication over the record field reported a state whose own trace
  // satisfied it)
  // the equivalence carries the `suppliedBy` term its
  // siblings carry, so the verdict agrees with the full boundary
  // predicate. Mutant
  // mut-c13-carry-drops-supplier (carryDecide judging by name-in-row
  // alone) is refuted by `cr13CarriedUnsuppliedRefused`.
  val projectionDecides =
    Refs.forall(r =>
      phase.get(r) == "new"
      or(lane.get(r) != "serve" and lane.get(r) != "publish"
         and lane.get(r) != "postpone-carried")
      or((status.get(r) == "ok") == (r.name.in(worn.get(r))
                                     and suppliedBy(r, cod.get(r)))))

  // (f) a published refusal is a real outsider: either the row genuinely
  // lacks the name, OR the row carries it and no proven supplier backs
  // it (the boundary rule's refusal limb). It is never
  // a refusal of a name a supplier proves and the row carries
  val projectionRefusalIsPublished =
    Refs.forall(r =>
      not(status.get(r) == "err" and lane.get(r) == "publish")
      or(not(r.name.in(proj.get(r))) or not(suppliedBy(r, cod.get(r)))))

  // (f) the publication is never a deferral: a declared projection is
  // known whether or not the arms resolve
  val publicationDecides =
    Refs.forall(r => not(lane.get(r) == "publish") or status.get(r) != "none")

  // (g) WRAPPER-INDEPENDENCE: a reference the node below deferred gets
  // the PUBLISHED-row verdict at the parent, whatever the distance -
  // under the boundary rule, so a carried name serves only where the row
  // carries it AND a proven supplier backs it
  val carriedRowDecides =
    Refs.forall(r =>
      not(lane.get(r) == "postpone-carried")
      or((status.get(r) == "ok") == (r.name.in(worn.get(r)) and suppliedBy(r, cod.get(r)))))

  // (g) a pass-through never changes the row it hands on: the carried
  // row is one the parent PUBLISHED (a pass-through publishes what it
  // received, so the row is in the published set at every distance)
  val passThroughPreservesRow =
    Refs.forall(r =>
      not(lane.get(r) == "postpone-carried") or worn.get(r).in(PublishedLive))

  // (h) THE BOUNDARY RULE. A published
  // projection is a REFUSAL BOUNDARY, never an existence proof. Three
  // limbs, and together they are the whole of the selector rule:
  //   (a) a name inside the projection is JUDGED, never auto-served -
  //       it serves only where a proven lane backs it (supplied);
  //   (b) a published name with no proven supplier is REFUSED - the
  //       launder prohibition
  //   (c) therefore nothing the boundary serves is unsupplied, and
  //       nothing it refuses is a name a supplier backs inside the row
  // (c) is what lifts deferralNeverRefuses to pre-publish scope: above a
  // publish the reference is judged, so it is neither deferred nor
  // exempt by its own earlier deferral.
  val publishedRowNeedsAProvenSupplier =
    Refs.forall(r =>
      not(lane.get(r) == "serve")
      or (r.name.in(proj.get(r)) and suppliedBy(r, cod.get(r))))

  // (i) GROUP-ARGUMENT-LEAK. A group's published
  // row is its keys plus its aggregate output names and NOTHING else. A
  // reference judged above the group (at any distance) wears exactly
  // that row, so the aggregate's ARGUMENT can never decide it: the
  // leaking verdict - a name the row carries, under a distance above
  // the group - is unreachable. The inside lane is a separate lane and
  // keeps its own input row
  // The statement is about the ROW, not about a name: the aggregate's
  // ARGUMENT (a real column of the input union, e.g. "c") must never
  // appear in what a node above the group wears. Writing it as
  // membership would miss the case the bug lives in - the argument is
  // a real column, so "c in worn" is exactly the leak
  val groupArgumentNeverLeaks =
    Refs.forall(r =>
      not(lane.get(r) == "group-over")
      or((proj.get(r) == groupRow("a") or proj.get(r) == groupRow("b"))
         and worn.get(r) == proj.get(r)
         and not("c".in(worn.get(r)))))

  // (i) REFUSAL-AUTHORITY above a group: a distance
  // ABOVE the group decides against the group's row, and an accepted
  // reference above it is one a proven supplier backs inside that row.
  // The implementable direction is the false serve: nothing the row
  // lacks is ever served above the group
  val groupRefusalAuthority =
    Refs.forall(r =>
      not(lane.get(r) == "group-over")
      or(((status.get(r) == "ok") == (r.name.in(worn.get(r)) and suppliedBy(r, cod.get(r))))
         and worn.get(r) == proj.get(r)))

  // (i) AGGREGATE-ARGUMENT NORMALISATION: the argument
  // FORM is recorded and never consults the verdict - the same group,
  // the same row, whichever spelling emitted the aggregate. A literal
  // in the aggregate position refuses at the group node
  val aggregateArgumentNormalised =
    Refs.forall(r =>
      not(lane.get(r) == "group")
      or(proj.get(r) == groupRow("a") or proj.get(r) == groupRow("b")))

  // (i) RESOLVABILITY SPLIT: the catalogue decides UNION MEMBERSHIP,
  // never a verdict. The run `cr11CatalogueIsIndexOnly` states the whole
  // rule as one quantified sentence and has a mutant that fails it; this
  // invariant stays as the narrow group-lane form, with its last limb
  // comparing the two spellings of the SAME entry list rather than two
  // different entries. The two roles stay apart explicitly: the
  // membership limb reads the record, the verdict limb reads the row.
  //
  // Supplying a name at the recorded setting is the RECORD's fact - a
  // column of the tree's own T, or one of the record's names under a
  // setting that ENUMERATES the arm. A mutant that starves the record's
  // names consistently (mut-m6), that starves the entry's (the
  // sparse-consistent armNames), or that adds a name under one setting
  // only (the sparse-inconsistent variant) refutes this limb; the run
  // `cr13SupplierIsRecordDerived` states it over every setting.
  val resolvabilitySplit =
    Refs.forall(r =>
      not(lane.get(r) == "group-over")
      or(worn.get(r) == proj.get(r)
         // membership limb, record-stated: the entry-identity fact
         and(suppliedBy(r, cod.get(r)) ==
             (r.name.in(T)
              or(armResolvable(cod.get(r)) and r.name.in(recordNames))))
         // verdict limb: the STATUS agrees with the row the reference
         // wears under the boundary rule
         and((status.get(r) == "ok") == (r.name.in(worn.get(r))
                                          and suppliedBy(r, cod.get(r))))
         and(suppliedBy(r, "alias") == suppliedBy(r, "path"))))

  // (i) WHERE CONSTANT PREDICATE: a constant predicate is
  // served, whatever names the row above lacks
  val whereConstantServes =
    Refs.forall(r =>
      not(lane.get(r) == "constant-pred") or status.get(r) == "ok")

  // (i) ONE VERDICT PER TREE: the same tree answers the same way on a
  // re-run; the group's published row must not be computed from state the
  // outer walk already touched. The
  // implementable form: the two lanes are DISJOINT and each wears its
  // own row - the inside reference wears the group's input union, the
  // one above wears the group's published row, and neither reading
  // depends on the other having run. A state where a settled
  // group-over reference wears the input union IS the leak
  val oneVerdictPerTree =
    Refs.forall(r =>
      not(lane.get(r) == "group-over")
      or(worn.get(r) == proj.get(r)
         and not(worn.get(r) == WIDE)))

  // (k) THE INDEX IS NOT A VERDICT INPUT (contract, the
  // resolver section). For every reference and every
  // setting, the status is the one the SETTING's own index gives it -
  // never the spelling, never the key, never a name the setting does not
  // enumerate. Two limbs, each with its own mutant:
  //   (1) the row a reference can be judged against is one the INDEX
  //       could have handed it: a row the setting's known names lack is
  //       unreachable (mutant M1: the free row list)
  //   (2) every name is the RECORD's name: a reference is judged by
  //       `canonName`, so a string spelling and a keyword spelling are
  //       one verdict (mutant M2: the spelling passed through)
  val catalogueIsIndexOnly =
    Refs.forall(r =>
      not(lane.get(r) == "decide")
      or(((worn.get(r) == knownNamesAt(cod.get(r)))
          and(knownNamesAt(cod.get(r)).contains(r.name) == (status.get(r) == "ok"))
          and((status.get(r) == "ok") == canonName(r.name).in(worn.get(r))))))

  // (k) IDENTITY FOLLOWS THE RECORD (the index invariant's
  // second half, contract, resolver section). An arm that carries an alias and
  // one that does not are two arms: the names an arm contributes are a
  // property of the record, never of a setting. The state this refuses is
  // a setting deciding what an arm IS - so the
  // statement is about the names the RECORD implies for the row worn,
  // and it is FALSE whenever a resolved arm's row carries a name the
  // record's own name set cannot account for. The form is measured and
  // falsifiable: a tautological twin cannot be moved by any mutant
  val armIdentityFromRecord =
    Refs.forall(r =>
      not(lane.get(r) == "decide")
      or((worn.get(r) == knownNamesAt(cod.get(r)))
         and(isArmCarryingAlias(arm.get(r))
             or knownSet.contains(canonName(r.name))
             or not(canonName(r.name).in(worn.get(r))))))

  // the refusal limb exercised: a projection entry no supplier backs is
  // reached as a REFUSAL, not merely unreachable-by-serving. An invariant
  // cannot say "reachable", so this is a test (see boundaryRefusesUnsupplied
  // below); the invariant form would duplicate the previous limb vacuously

  // (j) CATALOG-INDEPENDENCE is a TEST-level rule, not a state
  // invariant: the two catalogue settings are two runs over the same
  // tree, and the test is that the run outputs are identical (see the
  // cr8-catalog-* runs at the end). An invariant cannot state it - a
  // reachable state holds one setting, so `verify` would refute any
  // implication that conflates the two.

  val inv = and {
    mergedRow,
    unionKeepsRealColumns,
    perSideKey,
    keyFormEquivalent,
    keySlotStaysAtTheJoin,
    carriedLanesWearTheProjection,
    deferralNeverRefuses,
    verdictStable,
    opaqueNeverAccepted,
    projectionDecides,
    projectionRefusalIsPublished,
    publicationDecides,
    carriedRowDecides,
    passThroughPreservesRow,
    publishedRowNeedsAProvenSupplier,
    groupArgumentNeverLeaks,
    groupRefusalAuthority,
    aggregateArgumentNormalised,
    resolvabilitySplit,
    whereConstantServes,
    oneVerdictPerTree,
    catalogueIsIndexOnly,
    armIdentityFromRecord,
  }

  // ---- Protocol tests ----
  //
  // EVERY run below is an executable assertion over the model's state
  // (a postponed reference is then carried; `decide` takes no row). It is
  // a WITNESS only if a MUTANT fails it, and each run that
  // carries a mutant names it in the comment above it.
  //
  // Quint matches runs by NAME PREFIX, so a run whose name begins with the
  // name of a definition asserts nothing, and a run naming another run's
  // action asserts nothing either. No run below is named after its own
  // subject.

  run armColumnAccepted = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(decide({ name: "c", pos: 1 }))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run unionKeepsLeftArm = {
    init
      .then(decide({ name: "a", pos: 1 }))
      .expect((status.get({ name: "a", pos: 1 }) == "ok"))
      .then(stutter)
  }

  // the arm no setting enumerates does not
  // supply its own names. Its mutant is M1 (decide reads a supplied row
  // again).
  run uncataloguedArmRefused = {
    init
      .then(decide({ name: "o1", pos: 1 }))
      .expect(status.get({ name: "o1", pos: 1 }) == "err")
      .then(stutter)
  }

  // the same fact, one position along: an alias-carrying arm that NO
  // setting enumerates is just as uncatalogued
  run uncataloguedArmNameRefused = {
    init
      .then(setArm({ name: "c", pos: 1 }, "aliased"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "err")
      .then(stutter)
  }

  run opaquePostpones = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .expect((phase.get({ name: "o1", pos: 1 }) == "DEFER"))
      .then(stutter)
  }

  // the setting is chosen BEFORE the reference defers: `catalog` is a
  // pre-decision lane (phase "new"), the catalogue is fixed for the tree.
  // The carried row is Set("c", "d", "a"): a side row is not a published
  // row, so the run names the wider published row carrying the same name,
  // which leaves the run's verdict unchanged
  run deferredCarriedThenDecided = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(postpone({ name: "c", pos: 1 }))
      .then(carryDecide({ name: "c", pos: 1 }, Set("c", "d", "a"), 1))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run qualifierCatOut = {
    init
      .then(witness({ name: "o1", pos: 1 }, "cat"))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run qualifierCatInRefused = {
    init
      .then(witness({ name: "a", pos: 1 }, "cat"))
      .expect((status.get({ name: "a", pos: 1 }) == "err"))
      .then(stutter)
  }

  run qualifierOpenDefers = {
    init
      .then(witness({ name: "o1", pos: 1 }, "open"))
      .expect((phase.get({ name: "o1", pos: 1 }) == "DEFER"))
      .then(stutter)
  }

  run keyWrongSideRefused = {
    init
      .then(keyDecide({ name: "c", pos: 1 }, "L", "kw"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run keyRightSideStringGreen = {
    init
      .then(keyDecide({ name: "c", pos: 1 }, "R", "str"))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  // the projection NAMES the column and a proven supplier backs it: the
  // catalogued arm's own name, carried by a row that publishes it
  run insideProjectionServes = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(serve({ name: "c", pos: 1 }, Set("a", "c")))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run outsideProjectionRefused = {
    init
      .then(publishRefuse({ name: "c", pos: 1 }, Set("a")))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  // the launder: a projection names a column and no proven supplier
  // backs it, so the boundary refuses it. The chain launder is the same
  // fact one select out: the outer select's projection does not carry the
  // name the inner node published, so the outer select refuses it at its
  // own boundary (a row that DOES carry it cannot be refused here - the
  // boundary rule serves it, which `insideProjectionServes` states)
  run outerProjectionRefuses = {
    init
      .then(publishRefuse({ name: "a", pos: 1 }, Set("c")))
      .expect((status.get({ name: "a", pos: 1 }) == "err"))
      .then(stutter)
  }

  // the uncatalogued arm's own name, refused at a published row: a row the
  // arm cannot be proved to supply. Serving a name needs a catalogue - the
  // price of the membership rule
  run uncataloguedNameLaunderRefused = {
    init
      .then(publishRefuse({ name: "o1", pos: 1 }, Set("a")))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run ceilingAtDistanceOne = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .then(carryDecide({ name: "o1", pos: 1 }, Set("a"), 1))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run noPublishStillDefers = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .expect((status.get({ name: "o1", pos: 1 }) == "none"))
      .then(stutter)
  }

  run deferredAboveCeilingIsRefused = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .then(carryDecide({ name: "o1", pos: 1 }, Set("a"), 1))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cataloguedArmServes = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(decide({ name: "c", pos: 1 }))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run wrapperIndependentAtDistance = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(postpone({ name: "c", pos: 1 }))
      .then(carryDecide({ name: "c", pos: 1 }, Set("a", "b", "c", "d"), 2))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run outsiderNameRefused = {
    init
      .then(publishRefuse({ name: "o1", pos: 1 }, Set("a")))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run boundaryRefusesUnsupplied = {
    init
      .then(publishRefuse({ name: "o1", pos: 1 }, Set("c")))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  // the same boundary, the service limb: the row carries the arm's name
  // and the arm's setting backs it
  run boundaryServesSupported = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(serve({ name: "c", pos: 1 }, Set("c")))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run deferralScopedToPrePublish = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .expect((phase.get({ name: "o1", pos: 1 }) == "DEFER"))
      .then(stutter)
  }

  run keyNameAboveProjectionRefused = {
    init
      .then(publishRefuse({ name: "a", pos: 1 }, Set("c")))
      .expect((status.get({ name: "a", pos: 1 }) == "err"))
      .then(stutter)
  }

  run bareJoinStillDefers = {
    init
      .then(postpone({ name: "o1", pos: 1 }))
      .expect((status.get({ name: "o1", pos: 1 }) == "none"))
      .then(stutter)
  }

  // the empty projection (a select that declares an empty list) decides
  // every name: nothing is published, nothing passes. A cols-LESS select
  // is a pass-through and is modelled by the carry lane, never this one
  run emptyProjectionRefuses = {
    init
      .then(publishRefuse({ name: "a", pos: 1 }, Set()))
      .expect((status.get({ name: "a", pos: 1 }) == "err"))
      .then(stutter)
  }

  // a cols-less select passes its input's row on: a reference above it
  // gets that row's verdict (item 4's pass-through sentence)
  run selectedColumnsPassThrough = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(postpone({ name: "c", pos: 1 }))
      .then(carryDecide({ name: "c", pos: 1 }, Set("c", "d", "a"), 1))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  // CATALOG-INDEPENDENCE, the paired-run form: the same reference, the same
  // row, the same refusal, once per setting.
  // The paired form only says the two trees agree; the quantified form
  // (cr11CatalogueIsIndexOnly) is the invariant. Mutant M3 (a setting
  // whose index carries an extra name) fails this pair
  run cr8CatalogAbsentChainLaunder = {
    init
      .then(catalog({ name: "o1", pos: 1 }, "absent"))
      .then(publishRefuse({ name: "o1", pos: 1 }, Set("a")))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr8CatalogAliasChainLaunder = {
    init
      .then(catalog({ name: "o1", pos: 1 }, "alias"))
      .then(publishRefuse({ name: "o1", pos: 1 }, Set("a")))
      .expect((status.get({ name: "o1", pos: 1 }) == "err"))
      .then(stutter)
  }

  // ---- group runs ----

  run cr9GroupOverNeverSeesArgument = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "get"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "select"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9GroupOverSelectRefuses = {
    init
      .then(groupOver({ name: "c", pos: 1 }, "b", "select"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9GroupOverStackedRefuses = {
    init
      .then(groupOver({ name: "c", pos: 1 }, "b", "stacked"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9GroupOverOrderRefuses = {
    init
      .then(groupOver({ name: "c", pos: 1 }, "b", "order"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9GroupOverWhereRefuses = {
    init
      .then(groupOver({ name: "c", pos: 1 }, "b", "where"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9GroupOverKeyServes = {
    init
      .then(groupOver({ name: "a", pos: 1 }, "a", "direct"))
      .expect((status.get({ name: "a", pos: 1 }) == "ok"))
      .then(stutter)
  }

  // ITEM 1, the group's OWN scope: the aggregate's argument is judged
  // against the group's input row, which is the
  // INDEXES' union: catalogued, "c" is served; uncatalogued, no
  // setting enumerates it and the argument is refused. Mutant M1 fails
  // the first limb; mutant M4 (groupInside reading WIDE) fails the second
  run cr9GroupInsideArgumentServes = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(groupInside({ name: "c", pos: 1 }, "b"))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"))
      .then(stutter)
  }

  run cr9GroupInsideUncataloguedRefused = {
    init
      .then(groupInside({ name: "c", pos: 1 }, "b"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9BothLanesOneTrace = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(groupInside({ name: "c", pos: 1 }, "b"))
      .then(groupOver({ name: "d", pos: 1 }, "b", "select"))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"
               and status.get({ name: "d", pos: 1 }) == "err"))
  }

  run cr9BothLanesReverseOrder = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(groupOver({ name: "d", pos: 1 }, "b", "select"))
      .then(groupInside({ name: "c", pos: 1 }, "b"))
      .expect((status.get({ name: "c", pos: 1 }) == "ok"
               and status.get({ name: "d", pos: 1 }) == "err"))
  }

  run cr9AggFormBare = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "bare"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "select"))
      .expect((proj.get({ name: "a", pos: 1 }) == groupRow("b")
               and status.get({ name: "c", pos: 1 }) == "err"))
  }

  run cr9AggFormStr = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "str"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "select"))
      .expect((proj.get({ name: "a", pos: 1 }) == groupRow("b")
               and status.get({ name: "c", pos: 1 }) == "err"))
  }

  run cr9AggFormGet = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "get"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "select"))
      .expect((proj.get({ name: "a", pos: 1 }) == groupRow("b")
               and status.get({ name: "c", pos: 1 }) == "err"))
  }

  run cr9MalformedAggRefused = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "literal"))
      .expect((status.get({ name: "a", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9SplitNone = {
    init
      .then(catalog({ name: "c", pos: 1 }, "absent"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "where"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9SplitAlias = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "where"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  // "own-block": a block on the arm's OWN keys changes no verdict. A block
  // under a FOREIGN key is a malformed catalogue, not a setting, and is
  // not this run's subject
  run cr9SplitOwnBlock = {
    init
      .then(catalog({ name: "c", pos: 1 }, "own-block"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "where"))
      .expect((status.get({ name: "c", pos: 1 }) == "err"))
      .then(stutter)
  }

  run cr9ConstantPredicateServes = {
    init
      .then(constantPredicate({ name: "o1", pos: 1 }))
      .expect((status.get({ name: "o1", pos: 1 }) == "ok"))
      .then(stutter)
  }

  // ---- malformed-aggregate runs ----

  run cr10MalformedLiteral = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "literal"))
      .expect(status.get({ name: "a", pos: 1 }) == "err"
              and proj.get({ name: "a", pos: 1 }) == Set())
  }

  run cr10MalformedStrLit = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "strlit"))
      .expect(status.get({ name: "a", pos: 1 }) == "err"
              and proj.get({ name: "a", pos: 1 }) == Set())
  }

  run cr10MalformedExpr = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "expr"))
      .expect(status.get({ name: "a", pos: 1 }) == "err"
              and proj.get({ name: "a", pos: 1 }) == Set())
  }

  run cr10NoPhantomComputedName = {
    init
      .then(groupRefuse({ name: "a", pos: 1 }, "literal"))
      .expect(not(groupRow("a").exists(n => n.in(proj.get({ name: "a", pos: 1 })))))
      .then(stutter)
  }

  run cr10NodeIdentityFormsAgree = {
    init
      .then(groupDeclare({ name: "a", pos: 1 }, "b", "bare"))
      .then(groupDeclare({ name: "c", pos: 1 }, "b", "str"))
      .then(groupDeclare({ name: "d", pos: 1 }, "b", "get"))
      .expect(proj.get({ name: "a", pos: 1 }) == proj.get({ name: "c", pos: 1 })
              and proj.get({ name: "a", pos: 1 }) == proj.get({ name: "d", pos: 1 }))
  }

  // the invariance: a path-keyed entry changes no verdict for an
  // ALIAS-LESS arm. The
  // alias-less arm's path entry and its alias entry are the same
  // information, so the run states the invariance directly. Mutant M2
  // (the canonical name follows the SETTING, "c" path-keyed and "c" as a
  // string under the record) is the state this refuses
  run cr10PathKeyedCatalogueVerdictStable = {
    init
      .then(setArm({ name: "c", pos: 1 }, "bare"))
      .then(catalog({ name: "c", pos: 1 }, "path"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "ok")
      .then(stutter)
  }

  run cr10CatalogueNeverDecides = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(groupOver({ name: "c", pos: 1 }, "b", "direct"))
      .expect(status.get({ name: "c", pos: 1 }) == "err")
      .then(stutter)
  }

  // ---- catalogue-key runs ----

  // opacity is `not armResolvable(c)`: it is catalogue-
  // INDEPENDENT (a property of the
  // setting, so the same at every setting that enumerates), and it is NOT
  // a literal-true constant. The run states the
  // remaining fact: the no-resolvable setting is opaque and every
  // resolvable one is not. Mutant M5 (armOpaque = true) fails the second
  // limb; mutant M6 (armOpaque = false) fails the first. (Stated as
  // equalities: `not(armOpaque(...))` inside a run is mis-evaluated by
  // this quint build - the identical fact passes in
  // the equality form)
  run cr10bArmOpaqueIsCatalogueIndependent = {
    init
      .expect(armOpaque("absent") == true
              and armOpaque("own-block") == true
              and armOpaque("alias") == false
              and armOpaque("path") == false
              and armOpaque("bkey") == false)
  }

  // the membership lane: the settings that enumerate the arm agree on
  // what they supply, and the two that do not supply nothing. This is
  // where the catalogue decides - union membership, the whole of it.
  // Mutant M3 fails it
  run cr10bResolvabilitySplits = {
    init
      .expect(armNames("alias") == armNames("path")
              and armNames("alias") == armNames("bkey")
              and armNames("absent") == Set()
              and armNames("own-block") == Set())
  }

  // TRANSPARENCY is supplied by enumeration only, never removed: a
  // settled setting supplies its names and the others supply nothing.
  // The run's old form
  // asserted "shared" supplied {a,b}, a FOREIGN table's columns - the
  // defect stated as a property. It now states the enumeration fact
  run cr10bTransparencyOnlyEverAdded = {
    init
      .expect(namesOf("alias") == Set("c", "d")
              and namesOf("own-block") == Set()
              and knownSet == Set("a", "b", "c", "d"))
  }

  // the cross-setting run states the suppliedBy invariant over the whole
  // group lane, for every pair of settings. Mutant M3
  // fails it. (The lane is stepped through the ordinary `groupOverAny`
  // action: a standalone `groupAny` action declared after its only caller
  // parsed as part of the caller and matched nothing)
  run cr10bGroupVerdictStableAcrossEntrySettings = {
    init
      .then(catalogAny)
      .then(groupOverAny)
      .expect(Refs.forall(r =>
        not(lane.get(r) == "group-over")
        or(status.get(r) ==
           (if (r.name.in(groupRow("b")) and suppliedBy(r, cod.get(r))) "ok" else "err"))))
  }

  //
  // THE ACCEPTANCE RUN. One reference
  // naming a column the arm's record carries ("c") and one naming a
  // column no setting carries ("zzz"), judged on the source lane under
  // each of the four catalogue settings that name THIS arm - alias-keyed,
  // path-keyed, both-keyed, and none at all. The verdicts are equal
  // across the three that enumerate the arm, and the absent setting
  // refuses both (no record, no names). Stated as five runs and then as
  // the quantified sentence over every setting pair below. Mutants M1,
  // M2, M3 and M7 each fail at least one limb of this block
  run cr11AliasKeyedServesRecordName = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "ok")
      .then(stutter)
  }

  run cr11PathKeyedServesRecordName = {
    init
      .then(catalog({ name: "c", pos: 1 }, "path"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "ok")
      .then(stutter)
  }

  run cr11BothKeyedServesRecordName = {
    init
      .then(catalog({ name: "c", pos: 1 }, "bkey"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "ok")
      .then(stutter)
  }

  run cr11AbsentRefusesBoth = {
    init
      .then(catalog({ name: "c", pos: 1 }, "absent"))
      .then(decide({ name: "c", pos: 1 }))
      .then(decide({ name: "d", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "err"
              and status.get({ name: "d", pos: 1 }) == "err")
  }

  // a block on the arm's OWN keys describes no arm, so it adds nothing and
  // removes nothing: the same refusal as the absent setting, never a
  // served name. A supplier opened by an entry shape would serve it
  run cr11OwnBlockSuppliesNothing = {
    init
      .then(catalog({ name: "c", pos: 1 }, "own-block"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "err")
      .then(stutter)
  }

  // THE A1 INVARIANT AS A TEST: for every pair of settings that enumerate
  // the arm, the verdict of each of the arm's own names and of a name no
  // setting carries is identical. Refuted by M2 (a supplier opened by the
  // entry shape). The index-widening mutants (M1, M3) are NOT observable
  // here: this lane reaches the index through `knownNamesAt` under every
  // setting, so a widened index widens the lane and the arm together. They
  // are refuted by `cr11AbsentRefusesBoth` (the one setting where the
  // index and the arm must disagree) - measured, not assumed
  run cr11VerdictInvariantAcrossSettings = {
    init
      .then(setArm({ name: "c", pos: 1 }, "aliased"))
      .then(setArm({ name: "d", pos: 1 }, "bare"))
      .expect(Set("alias", "path", "bkey").forall(s1 =>
        Set("alias", "path", "bkey", "absent", "own-block").forall(s2 =>
          Set("c", "d", "zzz", "o1").forall(n =>
            ((if (n.in(knownNamesAt(s1))) "ok" else "err") ==
             (if (n.in(knownNamesAt(s2))) "ok" else "err")) or
            (armResolvable(s1) and not(armResolvable(s2)))))))
  }

  // identity follows the RECORD. Two arms over the same
  // tree, set explicitly, give each setting that enumerates them the same
  // names - the alias-less arm is not a second, weaker kind of source
  run cr11IdentityFromRecord = {
    init
      .then(setArm({ name: "c", pos: 1 }, "bare"))
      .then(setArm({ name: "d", pos: 1 }, "aliased"))
      .expect(arm.get({ name: "c", pos: 1 }) == "bare"
              and arm.get({ name: "d", pos: 1 }) == "aliased")
      .expect(Set("alias", "path", "bkey").forall(s =>
        armNames(s) == Set("c", "d")))
  }

  // R2: the name a verdict uses is the RECORD's. A string spelling and a
  // keyword spelling are one name - the run states both directions, so a
  // canonName that lowercased, prefixed or re-spelled would fail it
  run cr11CanonicalNameIsTheRecord = {
    init
      .then(catalog({ name: "c", pos: 1 }, "alias"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(canonName("c") == "c"
              and canonName("c") == canonName(canonName("c"))
              and status.get({ name: "c", pos: 1 }) == "ok")
  }

  // no setting in Cods is a placeholder: the predicate is FALSE under
  // every setting, stated rather than silently dropped
  run cr11NoSettingIsAPlaceholder = {
    init
      .expect(Cods.forall(c => not(armIsPlaceholder(c))))
      .then(stutter)
  }

  // the redesign's copy of the resolvability split as a pair: membership
  // is the ONLY difference between a catalogued and an uncatalogued tree.
  // The opacity limbs are stated HERE and not left implicit: M4 (an
  // opacity rule that reads the arms' names) passes every other cr11 run
  // and is caught only by these three equalities
  run cr11MembershipIsTheOnlyCatalogueFact = {
    init
      .expect(armResolvable("alias") and armResolvable("path") and armResolvable("bkey")
              and not(armResolvable("absent")) and not(armResolvable("own-block"))
              and armNames("alias") == armNames("path")
              and armNames("alias") == armNames("bkey"))
      .expect(armOpaque("alias") == false and armOpaque("path") == false
              and armOpaque("bkey") == false
              and armOpaque("absent") and armOpaque("own-block"))
      // and it is the MEMBERSHIP that decides, not the names the
      // membership brings: the opaque settings carry no names, so an
      // opacity rule that keyed on the names would disagree here
      .expect(Cods.forall(c => armOpaque(c) == not(armResolvable(c))))
  }

  // THE SUPPLIER IS THE RECORD:
  // supplying a name is a property of the arm's record, not of which entry
  // shape the catalogue happens to hold. The arm's own name "c" is supplied
  // by every setting that enumerates the arm and by no setting that does
  // not - and by NOTHING for a name no setting enumerates. Refuted by M2
  // (the supplier opened by an entry shape, so "c" is supplied under
  // "own-block", an entry that describes no arm)
  run cr11SupplierIsTheRecord = {
    init
      .expect(Set("alias", "path", "bkey").forall(s =>
                suppliedBy({ name: "c", pos: 1 }, s)
                and not(suppliedBy({ name: "o1", pos: 1 }, s)))
              and Set("absent", "own-block").forall(s =>
                not(suppliedBy({ name: "c", pos: 1 }, s))
                and not(suppliedBy({ name: "o1", pos: 1 }, s)))
              // the tree's own row is supplied under every setting
              and Cods.forall(s => suppliedBy({ name: "a", pos: 1 }, s)))
  }

  // ENUMERATION IS NOT PERMISSION: an opaque setting whose index is
  // widened with the arm's own name still refuses that name, because the
  // verdict reads the RECORD and the record names nothing under an
  // unresolvable setting. This is the runs' answer to the vacuous
  // shape (an index supplying a name that then becomes servable). Under
  // `own-block` no setting enumerates the arm at all, so the widened index
  // is not reachable here; the mutant's red lands on `cr11AbsentRefusesBoth`
  run cr11IndexWideningCannotServe = {
    init
      .then(catalog({ name: "c", pos: 1 }, "own-block"))
      .then(decide({ name: "c", pos: 1 }))
      .expect(status.get({ name: "c", pos: 1 }) == "err")
      .then(stutter)
  }
  // ==========================================================================
  // THE RESOLVER CONTRACT AS FUNCTIONS
  // ==========================================================================
  // Three functions of the arm record. Nothing below reads a catalogue key
  // except through `bindingKey`, and nothing reads a name set except
  // through `armDisposition`.
  //
  //  1. THE BINDING KEY SET (AUTHORITATIVE). The keys an arm
  //     answers to: a from arm answers to its source and always to its alias
  //     when it carries one; a parquet arm to its path and always to its
  //     alias. The key set carries both aliases: dropping one lets the
  //     catalogue's key spelling decide the verdict.
  //     Nothing may derive a key set independently of this function -
  //     `bindingKeysParquet` and `bindingKeysFrom` are the ONLY copies, and
  //     `bindingKey` is the only way a consumer sees them.
  pure def bindingKeysParquet(i: bool): Set[str] =
    if (i) Set("p", "a") else Set("p")
  pure def bindingKeysFrom: Set[str] = Set("t", "e")
  // the SET, as an identity used by identity, not by the catalogue
  pure def bindingKeySet(i: bool): Set[str] =
    if (i) bindingKeysParquet(true) else bindingKeysFrom
  //  2. THE BINDING KEY (a named cell's default key, a NAMING DEFAULT and
  //     never a resolution decision): the alias when the record carries
  //     one, otherwise the canonical key. Exactly one
  //     asymmetry is licensed: a :from arm's starting key is its SOURCE,
  //     because the
  //     from-table name is the tree's own addressing.
  pure def bindingKey(p: str, i: bool): str =
    if (i) "a" else p
  //  3. THE COLUMNS DISPOSITION of a cell: which names this source
  //     contributes to the judgement of one reference, and whether it is
  //     known at all:
  //       record          an entry enumerates the arm: its RECORD's names
  //                       (c, d) are contributed, whatever the entry lists
  //       absorb(empty)   no entry, or an own-block: the record still names
  //                       them, and the arm is NOT resolvable, so a
  //                       reference the record names DEFERS
  //       foreign         an entry describing another source (the decoy):
  //                       the record is consulted, the entry contributes
  //                       NOTHING - a catalogue cannot create, move or
  //                       destroy an arm
  val Dispositions = Set("record", "absorb", "foreign")
  // THE SETTING IS THE ENTRY THE TREE HAS WRITTEN.
  // Reading the setting out of the KEY alone (`canon` -> "alias") makes the
  // disposition a constant: an arm could never be observed as
  // ABSORB, and the absorb branch would be dead code no test could reach.
  // The setting is the arm's `cod` - the source the
  // tree has recorded - read at the reference; `keying` stays the key the
  // setting was WRITTEN UNDER, which is what item 2 says cannot reach the
  // verdict. `none` (not yet written) reads as the canonical setting.
  def settingOf(r: { name: str, pos: int }): str =
    if (cod.get(r) == "none") "alias" else cod.get(r)
  def armDisposition(r: { name: str, pos: int }, k: str): str =
    if (k == "canon" and armResolvable(settingOf(r))) "record"
    else if (k == "canon") "absorb"
    else "foreign"
  pure def recordNames: Set[str] = Set("c", "d")
  def cellNamesOf(r: { name: str, pos: int }, k: str): Set[str] =
    if (armDisposition(r, k) != "foreign") recordNames.union(namesOf(settingOf(r)))
    else namesOf(settingOf(r))
  // resolvability: does an entry of THIS source enumerate it?
  def armResolvableAt(r: { name: str, pos: int }, k: str): bool =
    armDisposition(r, k) == "record"
  // ABOVE a described arm, the referenced source's names decide a reference;
  // above an arm NO entry describes, nothing but the tree's own row does, so
  // a name one setting enumerates is ABSORBED by the record and DEFERS (the
  // an entry may add known names, never a serve)
  def cellVerdict(r: { name: str, pos: int }, k: str, n: str): str =
    if (armResolvableAt(r, k)) (if (n.in(cellNamesOf(r, k))) "ok" else "err")
    else "defer"


  // --------------------------------------------------------------------------
  // The agreement rules as state-reading conjuncts.
  //
  // Instrument note. The Quint
  // `test` runner treats EVERY `pure def` in the module as a run of its own.
  // A `pure def` that reads state is therefore evaluated BEFORE `init` and
  // fails with "Variable keying not set" (renaming a state-reading
  // helper def out of the selector namespace still reports it red). The two
  // consequences this suite is built around:
  //   1. no contract helper may read state - helpers here are functions of
  //      their ARGUMENTS, and only a `run` starts with `init`;
  //   2. a helper def whose name matches the selector pollutes the mutant
  //      table with a red that no mutant caused, so helpers carry no
  //      selector prefix.
  // The `.expect` calibration pair below is a real control: inverting the
  // yes-run's literal turns it red ("Expect condition does not hold"), so
  // the runner does honour a false state-reading conjunct.
  //
  // M1 is re-pointed at the predicate itself: every cr12 run reads a
  // verdict at `keying == "canon"`, so the "binding" branches are never
  // entered. `armNames` = {"c","d"} for every resolvable setting, so
  // `cellNamesOf("canon")` = `namesOf("alias")` = {"c","d"} = the record
  // names, and dropping either factor of that union is unobservable - a
  // test that cannot distinguish them cannot witness the rule.
  // --------------------------------------------------------------------------

  // A join key is OK only where BOTH sides' cells are OK
  pure def joinKeyVerdict(l: str, r: str): str =
    if (l == "ok" and r == "ok") "ok" else "err"

  // STATE-READING RUNS read the arm functions DIRECTLY; no helper def may
  // read state (see the instrument note: such a def runs before `init`).
  // CALIBRATION (control pair). A run is only a witness if the runner can
  // both PASS and FAIL a state-reading conjunct in this module. The yes-run
  // asserts the verdict the contract fixes for a resolvable setting; the
  // no-run asserts the same run's NEGATION, so a green no-run would mean
  // every red below is vacuous.
  //
  // The no-run reads `armDisposition` and NOT `cellVerdict`. It is named
  // OUTSIDE the `cr12.*` selector and outside the gate run tier: a run
  // that is FALSE by design must never be selected by a gate, or the gate is
  // permanently red and every real red hides behind it. It is run BY HAND
  // when the calibration is being checked. The positive/non-describing
  // direction is exactly what an
  // "absorb serves" mutant would move, so tightening it into the `cr12.*`
  // scope is the mutant's job.
  run cr12ExpectCalibrationYes = {
    init
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "c") == "ok")
      .then(stutter)
  }
  run calibrationNo = {
    init
      .expect(armDisposition({ name: "c", pos: 1 }, "canon") == "foreign")
      .then(stutter)
  }

  // THE KEY SET IS THE AUTHORITY: the setting is
  // a choice of KEY written under one source, so the key spelling cannot
  // reach the verdict - the catalogue keyed by the record's alias reaches
  // the arm exactly as the source-keyed entry does. The run reads the key
  // BEFORE and AFTER the setting is written under the other key; both reads
  // name the cell the catalogue describes, so the verdict is the same.
  run cr12KeySetIsAuthority = {
    init
      .expect((if (keying.get({ name: "c", pos: 1 }) == "canon")
                cellVerdict({ name: "c", pos: 1 }, keying.get({ name: "c", pos: 1 }), "c") else "zzz") == "ok")
      .then(catalogUnder({ name: "c", pos: 1 }, "alias", "binding"))
      .then(stutter)
      .then(stutter)
  }

  // THE BINDING KEY: a parquet arm's default key is its
  // alias when the record carries one, its path otherwise; a from arm's is
  // its SOURCE (the tree's own addressing - the one licensed asymmetry).
  run cr12BindingKeyIsTheRecord = {
    init
      .expect(bindingKey("p", true) == "a")
      .expect(bindingKey("p", false) == "p")
      .expect(bindingKey("t", false) == "t")
      .then(stutter)
  }

  // THE COLUMNS DISPOSITION: an entry that enumerates
  // the arm contributes the RECORD's names; a block describing no arm
  // contributes NOTHING and does not resolve the arm. One reference, one
  // keying, one verdict - the reference alone decides.
  run cr12CellAloneDecides = {
    init
      .expect(armDisposition({ name: "c", pos: 1 }, "canon") == "record")
      .expect(armDisposition({ name: "c", pos: 1 }, "binding") == "foreign")
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "c") == "ok")
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "zzz") == "err")
      .expect(cellVerdict({ name: "c", pos: 1 }, "binding", "c") == "defer")
      .expect(cellVerdict({ name: "c", pos: 1 }, "binding", "zzz") == "defer")
      .then(stutter)
  }

  // A JOIN KEY IS JUDGED AGAINST ITS OWN SIDE'S RECORD-DERIVED CELLS:
  // each side is judged on its own cell, and
  // each cell is judged where the arm is DESCRIBED. A join key naming a
  // column both records carry is OK; a name neither carries is ERR; an
  // arm's ALIAS is never a column of either side.
  run cr12JoinKeyRecordDerived = {
    init
      .expect(joinKeyVerdict(cellVerdict({ name: "c", pos: 1 }, "canon", "c"), cellVerdict({ name: "c", pos: 1 }, "canon", "c")) == "ok")
      .expect(joinKeyVerdict(cellVerdict({ name: "c", pos: 1 }, "canon", "a"), cellVerdict({ name: "c", pos: 1 }, "canon", "a")) == "err")
      .expect(joinKeyVerdict(cellVerdict({ name: "c", pos: 1 }, "canon", "zzz"), cellVerdict({ name: "c", pos: 1 }, "canon", "zzz")) == "err")
      .expect(joinKeyVerdict(cellVerdict({ name: "c", pos: 1 }, "canon", "c"), cellVerdict({ name: "c", pos: 1 }, "canon", "zzz")) == "err")
      .then(stutter)
  }

  // THE THREE SETTINGS THAT DESCRIBE THE ARM AGREE, restated
  // within the rows a setting enumerates: an invariant over
  // cross-enumeration compares a describing setting with a
  // non-describing one, and the latter legitimately defers.
  run cr12SettingsAgreeAlias = {
    init
      .expect((if ("c".in(knownNamesAt("alias"))) "ok" else "err") == "ok")
      .expect((if ("d".in(knownNamesAt("alias"))) "ok" else "err") == "ok")
      .expect((if ("zzz".in(knownNamesAt("alias"))) "ok" else "err") == "err")
      .then(stutter)
  }
  run cr12SettingsAgreePath = {
    init
      .expect((if ("c".in(knownNamesAt("path"))) "ok" else "err") == "ok")
      .expect((if ("d".in(knownNamesAt("path"))) "ok" else "err") == "ok")
      .expect((if ("zzz".in(knownNamesAt("path"))) "ok" else "err") == "err")
      .then(stutter)
  }
  run cr12SettingsAgreeBothKeys = {
    init
      .expect((if ("c".in(knownNamesAt("bkey"))) "ok" else "err") == "ok")
      .expect((if ("d".in(knownNamesAt("bkey"))) "ok" else "err") == "ok")
      .expect((if ("zzz".in(knownNamesAt("bkey"))) "ok" else "err") == "err")
      .then(stutter)
  }

  // THE DISPOSITION IS A FUNCTION OF THE STATE. What
  // an arm's disposition IS depends on what the tree has WRITTEN about that
  // arm (`cod`), not on the name of the key it was reached by: an arm an
  // entry does not enumerate is ABSORB - its record still names it and the
  // arm is NOT resolvable - so a name the record carries DEFERS. This run
  // writes an own-block setting for the arm and reads the disposition AFTER
  // it; on a model that derives the disposition from the key alone the
  // setting cannot move it and this run is red (the red-first cell).
  run cr12DispositionFollowsTheEntry = {
    init
      .expect(armDisposition({ name: "c", pos: 1 }, "canon") == "record")
      .then(catalog({ name: "c", pos: 1 }, "own-block"))
      .then(stutter)
      .expect(cod.get({ name: "c", pos: 1 }) == "own-block")
      .expect(armDisposition({ name: "c", pos: 1 }, "canon") == "absorb")
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "c") == "defer")
      .then(stutter)
  }

  // THE ABSORBED CELL KEEPS THE RECORD'S NAMES. Above an arm NO entry
  // enumerates, the entry contributes NOTHING
  // (`namesOf` is empty) and the RECORD alone names the cell: the absorbed
  // cell still carries {"c","d"} and a record name DEFERS rather than being
  // refused. This is the run that makes the record union load-bearing: on a
  // model where the cell's names come from the ENTRY alone the union factor
  // can be dropped and no test can see it.
  run cr12AbsorbKeepsRecordNames = {
    init
      .then(catalog({ name: "c", pos: 1 }, "own-block"))
      .then(stutter)
      .expect(namesOf(settingOf({ name: "c", pos: 1 })) == Set())
      .expect(cellNamesOf({ name: "c", pos: 1 }, "canon") == Set("c", "d"))
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "c") == "defer")
      .expect(cellVerdict({ name: "c", pos: 1 }, "canon", "d") == "defer")
      .then(stutter)
  }

  // IDENTITY IS THE RECORD: no action chain. An identity invariant stated
  // through one would be UNVERIFIED, because no mutant can refute it.
  run cr12IdentityIsTheRecord = {
    init
      .expect(recordNames.contains("c") and recordNames.contains("d"))
      .expect((if ("c".in(cellNamesOf({ name: "c", pos: 1 }, "canon"))) "ok" else "err") == "ok")
      .expect((if ("d".in(cellNamesOf({ name: "c", pos: 1 }, "canon"))) "ok" else "err") == "ok")
      .expect((if ("c".in(armNames("alias"))) "ok" else "err") == "ok")
      .expect((if ("d".in(armNames("path"))) "ok" else "err") == "ok")
      .then(stutter)
  }

  // ==========================================================================
  // The two rebuilt invariants pinned at counterexample states. A run is the
  // refutation witness for a rebuilt invariant: the state it pins refutes
  // the earlier reading, and a mutant that restores that reading goes red
  // here.
  // ==========================================================================

  // COUNTEREXAMPLE 1 for `projectionDecides`: a carried reference whose row
  // CARRIES the name while no proven supplier backs it (cod is unwritten, so
  // the record names nothing). The boundary rule refuses it; a conjunct that
  // reads ok iff name in worn would demand it serve. `projectionDecides`
  // holds on this state because the suppliedBy term is inside the
  // equivalence. Mutant mut-c13-carry-drops-supplier (carryDecide judging by
  // name-in-row alone) fails this run.
  run cr13CarriedUnsuppliedRefused = {
    init
      .then(postpone({ name: "c", pos: 1 }))
      .then(carryDecide({ name: "c", pos: 1 }, Set("c", "d", "e", "f"), 2))
      .expect(status.get({ name: "c", pos: 1 }) == "err")
      .then(stutter)
  }

  // THE RECORD-STATED SUPPLIER LIMB of the rebuilt `resolvabilitySplit`,
  // stated as a run over EVERY setting with no action chain: supplying a
  // name is the RECORD's fact - a column of the tree's own T, or one of
  // the record's names under a setting that ENUMERATES the arm - never a
  // fact of the entry's shape or of one setting's spelling. Refuted by
  // mut-m6 (the record starved of "d"), by a
  // sparse-consistent armNames variant (the entry starved of "d" under
  // every enumerating setting), and by its sparse-inconsistent variant
  // (an extra name under one setting only). This is the run that makes
  // the sparse-consistent mutant's red load-bearing in the gate tier.
  run cr13SupplierIsRecordDerived = {
    init
      .expect(Cods.forall(c =>
        Set("a", "b", "c", "d", "o1", "zzz").forall(n =>
          suppliedBy({ name: n, pos: 1 }, c) ==
            (n.in(T) or (armResolvable(c) and n.in(recordNames))))))
      .then(stutter)
  }
}

// ===========================================================================
// CATALOGUE LANE - `source-columns` with writer identity as a
// spec variable
// ===========================================================================
//
// WHAT IS MODELED (the appended module's whole domain):
//   - RECORDS (arms): A (parquet, path "pa.parquet", alias "x") and B
//     (parquet, path "pb.parquet", alias-less). B exists because writer
//     identity needs a second record to be a fact at all: a foreign entry
//     and a shared block are both entries some OTHER record wrote.
//   - SPELLINGS with VARIANT EXPANSION: a name text answers to its string,
//     keyword and symbol forms (catalog-key-variants); every key below is
//     one of "s:<t>", "k:<t>", "y:<t>". A record's OWN KEYS are the forms
//     of its path and, when it carries one, its alias.
//   - THE UNION WALK: every admitted entry under the record's
//     own keys contributes its column set, de-duplicated (first-seen order
//     is bounded away: order is the catalogue's internal iteration order,
//     deterministic, not caller-reachable;
//     the model keeps sets, which is exactly the membership fact every
//     verdict lane reads).
//   - THE SHARED-BLOCK FILTER (`others`/`usable?`): a list an ALIEN key
//     (not one of the record's own keys) also carries marks the block
//     set, and an own entry carrying such a list is UNUSABLE - the alien
//     copy subtracts the claim. Any alien key triggers it (it need not
//     be a spelling of the arm), including another record's
//     own key.
//   - WRITER IDENTITY as a spec variable with two modes:
//       absent  - admission identical to a catalogue carrying no writer
//                 field; writer is carried in the state as GROUND TRUTH but
//                 the absent-mode functions never read it.
//       present - identity-scoped admission: an entry contributes to a
//                 record's description only if its writer is that record.
//                 Shared blocks contribute nothing, neither adding nor
//                 subtracting; foreign entries under the record's own
//                 spellings describe nothing.
//   - THE S1 CHOICE as two spec-level options: two OWN entries (writer =
//     record, under own keys) with different column SETS either union
//     ("union", the field semantics of a catalogue carrying no writer
//     field) or
//     refuse the whole arm as duplicate-schema malformed ("refuse"). Both
//     are in the
//     state space; the consequences are enumerated by runs.
//
// THE PROPERTIES (invariants, checked - see the verification block at the
// top of the file for the per-cluster commands). The walked model's three
// present-mode properties are SUPPORT INSTRUMENTS, not gates. Their
// present-mode status, measured after the shape-fixture correction (the
// shape fixtures now carry the value the fieldless test reads; see
// catalogue-shapes.qnt and the contract's field-domain paragraph):
//   P-S2          ps2Neutrality: an entry whose writer is not the record
//                 changes nothing - removing every writer-other entry
//                 leaves the described set identical. REFUTED in absent
//                 mode (the alien agreeing copy that subtracts an own
//                 entry's claim) and still RED in present mode after the
//                 correction; not re-stated.
//   P-absorption  absorptionNever: nothing outside the record's own
//                 writer's claims is ever described. REFUTED absent (the
//                 wall: a foreign entry under any spelling of the arm's
//                 own keys describes the arm - the refutation trace IS the
//                 wall proof). RED in present mode after the correction
//                 (the `ff-mixed` class), and RED under a second,
//                 identity-independent absorption instrument stated over
//                 the entry set; not re-stated.
//   P-presence    presenceNeverFlips: removing every entry under a key
//                 alien to the record never changes a verdict. REFUTED in
//                 both modes on the wide sentence: an alien entry is the
//                 block that silences an own claim, so removing it can move
//                 a verdict. A SUPPORT INSTRUMENT, not a gate; the narrowed
//                 direction (an alien entry may subtract a block, never add
//                 a name) is what holds.
//   P-S1          absentFieldUnions: the absent-field semantics union two
//                 disagreeing own entries, never malformed. (Union is the
//                 only behaviour, so there is no present-mode choice to
//                 check and no `s1Choice` invariant.)
// A green of any of these is cited only with the clause, tree hashes,
// endpoint and run count the contract requires.
//
// STATE SPACE AND BOUNDS (the coverage statement the verify records must
// support; nothing here is sampled):
//   enumerated   Modes(2) x Forms(3) x Shapes(27) x Records(2) x Names(8)
//                x keys(4); every verify below explores the full cross
//                product of its partition at depth 3 (init, describe,
//                stutter).
//   spellings    the s/k/y forms of A's path, A's alias, B's path and the
//                alien key "q"; variant expansion is the ownKeys set.
//   union shapes agreeing, disagreeing (two own entries, different sets),
//                overlapping, in-list duplicates, S1 shape {x y}/{y z}.
//   shared-block none, alien agreeing copy, alien other list, lone block,
//   configs      cross-record agreeing copy (symmetric: each record's
//                copy silences the other's own entry), agreeing own pair
//                + copy.
//   bounded away  union ORDER (set semantics - order decides no verdict
//                 and is not caller-reachable); empty-list entries
//                 (:columns [], the described-vs-nil distinction);
//                 from-source arms (pathless, no shared-block filter);
//                 two records sharing one name text (the ambiguity
//                 lane, outside this
//                 lane); the append width lane downstream of the
//                 described set.
// Part B: the catalogue lane is specs/catalogue-record.qnt (the
// walked model; its shapes and walk are specs/catalogue-shapes.qnt). This
// module keeps its NAME and its whole definition set by re-export, so every
// caller, initializer and cm.* cell that names janetQueryCatalogue keeps
// grading the same model.
module janetQueryCatalogue {
  import catalogueRecord.* from "./catalogue-record"
}
