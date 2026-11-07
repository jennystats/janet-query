// janet-query catalogue lane, Part B: the WRITER-IDENTITY model.
// Sibling module: its own state space, its
// own initializer and stutter, one-way imports of pure definitions only.
//
// THE WALK: two lanes, chosen by whether an entry's writer RESOLVES to a
// record. Spelled out here rather than reusing the landed present walk, so
// a walk mutant and an oracle mutant live in different files.
//
// THE ORACLE is the writer-identity rule on its own alphabet: (a) own key,
// (b) no alien-key entry carries the list, (c) the writer resolves to the
// record (NECESSARY); a fieldless entry takes the absent-field admission,
// stated here as its own predicate.
//
// RECURSION LIMIT (named): the oracle shares (a) and (b) with the walk, so
// the properties instrument ADMISSION-SHAPE changes, not independent
// semantics. The independent anchor is the absent-mode baseline, pinned by
// the 2a cell and the cross-copy family.

module cataloguePartB {
  import catalogueRecord.* from "./catalogue-record"
  import catalogueShapes.* from "./catalogue-shapes"

  // ---- the model ----
  // THE WALK: two lanes, chosen by whether the entry's writer RESOLVES to a
  // record. Lane 1 (resolves): the writer-identity rule's necessary condition
  // plus the
  // absent-field key scoping and the block rule. Lane 2 (names no
  // record): a catalogue carrying no writer field - the imported absence walk
  // over the entries resolution does not
  // testify for. Spelled out rather than calling unionPresent, so a mutant on
  // the walk and a mutant on the oracle live in DIFFERENT FILES.
  pure def laneNames(w: str): Set[str] =
    if (w == "A") Set("A")
    else if (w == "B") Set("B")
    else if (w == "wr-A") Set("A")
    else if (w == "wr-B") Set("B")
    else Set()

  pure def admitTestimony(e: Ent, cat: Set[Ent], r: str): bool =
    e.key.in(ownKeys(r))
    and not(e.cols.in(entryLists(cat, r)))
    and laneNames(e.writer).contains(r)
    and not(e.cols == Set())

  // lane 2 keeps the WHOLE catalogue: the absent-mode walk reads the alien
  // block evidence, and only its admission test is restricted
  // lane 2's admission set: a fieldless entry is admitted iff it sits under
  // an own key, no entry under a key ALIEN to the record carries its list
  // (the block rule, read over the whole catalogue), and it says something
  pure def fieldFreeUsable(e: Ent, cat: Set[Ent], r: str): bool =
    not(laneNames(e.writer).size() > 0)
    and e.key.in(ownKeys(r))
    and not(e.cols.in(entryLists(cat, r)))
    and not(e.cols == Set())

  pure def admitFieldFree(cat: Set[Ent], r: str): Set[str] =
    cat.filter(x => fieldFreeUsable(x, cat, r)).map(x => x.cols).flatten()

  pure def unionWalk(cat: Set[Ent], r: str): Set[str] =
    cat.filter(e => admitTestimony(e, cat, r)).map(e => e.cols).flatten()
    .union(admitFieldFree(cat, r))

  pure def verdictWalk(cat: Set[Ent], r: str, n: str): str =
    if (unionWalk(cat, r) != Set())
      (if (n.in(unionWalk(cat, r))) "ok" else "err")
    else if (blockedByOwnValue(cat, r))
      "defer"
    else
      "undescribed"

  // THE ORACLE: the writer-identity rule on its own alphabet. Nothing here
  // reads
  // unionWalk / admitTestimony / admitFieldFree; the subject's keys are
  // stated as literals, not obtained from the model's keyOf.
  pure def pbNames(w: str): Set[str] =
    if (w == "A") Set("A")
    else if (w == "B") Set("B")
    else if (w == "wr-A") Set("A")
    else if (w == "wr-B") Set("B")
    else Set()

  pure def pbOwnKeys(r: str): Set[str] =
    if (r == "A")
      Set("s:pa.parquet", "k:pa.parquet", "y:pa.parquet",
          "s:x", "k:x", "y:x")
    else
      Set("s:pb.parquet", "k:pb.parquet", "y:pb.parquet")

  pure def pbAlienLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => not(e.key.in(pbOwnKeys(r)))).map(e => e.cols)

  pure def pbTestimonyLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => e.key.in(pbOwnKeys(r)) and pbNames(e.writer).contains(r))
       .map(e => e.cols)

  // THE ORACLE: the writer-identity rule on its own alphabet.
  //   (a) own key; (b) no alien-key entry carries the list (the block rule);
  //   (c) the writer RESOLVES to the record
  //   (NECESSARY) - a fieldless entry is not testimony and takes the
  //   absent-field admission, stated here as its own predicate.
  // Recursion limit (named): the oracle shares (a) and (b) with the walk by
  // the letter's own design; it does not call the walk.
  pure def pbFieldlessAdmission(e: Ent, cat: Set[Ent], r: str): bool =
    e.key.in(pbOwnKeys(r))
    and not(e.cols.in(pbAlienLists(cat, r)))
    and not(e.cols == Set())

  pure def pbOracle(cat: Set[Ent], r: str): Set[str] =
    cat.filter(e =>
         if (pbNames(e.writer).size() > 0)
           pbFieldlessAdmission(e, cat, r) and pbNames(e.writer).contains(r)
         else
           pbFieldlessAdmission(e, cat, r))
       .map(e => e.cols).flatten()

  // the record's own writer's claims (the oracle's own alphabet)
  pure def pbOwnUnion(cat: Set[Ent], r: str): Set[str] =
    cat.filter(e => e.key.in(pbOwnKeys(r)) and pbNames(e.writer).contains(r))
       .map(e => e.cols).flatten()

  // ---- S1's witnesses, stated by name ----
  pure def s1ShapeOk(shape: str, f: str): bool =
    if (shape == "own-agree")
      (verdictWalk(shCat(shape, f), "A", "a") == "ok"
       and verdictWalk(shCat(shape, f), "A", "b") == "ok"
       and verdictWalk(shCat(shape, f), "A", "q") == "err")
    else if (shape == "own-disagree")
      (Cols.forall(n => verdictWalk(shCat(shape, f), "A", n) != "malformed")
       and verdictWalk(shCat(shape, f), "A", "a") == "ok"
       and verdictWalk(shCat(shape, f), "A", "c") == "ok")
    else if (shape == "own-overlap")
      (verdictWalk(shCat(shape, f), "A", "c") == "ok"
       and verdictWalk(shCat(shape, f), "A", "a") == "ok")
    else if (shape == "s1-shape")
      (verdictWalk(shCat(shape, f), "A", "x") == "ok"
       and verdictWalk(shCat(shape, f), "A", "z") == "ok"
       and verdictWalk(shCat(shape, f), "A", "b") == "err")
    else if (shape == "own-dup")
      (verdictWalk(shCat(shape, f), "A", "q") == "ok"
       and verdictWalk(shCat(shape, f), "A", "c") == "err")
    else
      true

  // ---- one cell per configuration, written by the initializer ----
  var pbdesc: Set[str]
  var pbverdict: str
  var pbOracleDesc: Set[str]
  var pbPrunedVerdict: str
  var pbshape: str
  var pbform: str
  var pbsubj: str
  var pbname: str
  var pbmode: str
  var pbdone: bool

  // TWO initializers, one per side of the comparison: the walk model and
  // the oracle model. (One init writing eleven independent columns asks the
  // bounded solver for an unrefined product; the split is the same model.)
  action pbInit =
    nondet shape = Shapes.oneOf();
    nondet form = Forms.oneOf();
    nondet subj = Records.oneOf();
    nondet name = Cols.oneOf();
    nondet mode = Modes.oneOf();
    all {
      pbdesc' = unionWalk(shCat(shape, form), subj),
      pbverdict' = verdictWalk(shCat(shape, form), subj, name),
      pbOracleDesc' = pbOracle(shCat(shape, form), subj),
      pbPrunedVerdict' = verdictWalk(prunedOfAlien(shCat(shape, form), subj), subj, name),
      pbshape' = shape, pbform' = form, pbsubj' = subj, pbname' = name, pbmode' = mode,
      pbdone' = true,
    }

  action pbStutter =
    all {
      pbdesc' = pbdesc, pbverdict' = pbverdict,
      pbOracleDesc' = pbOracleDesc, pbPrunedVerdict' = pbPrunedVerdict,
      pbshape' = pbshape, pbform' = pbform, pbsubj' = pbsubj, pbname' = pbname,
      pbmode' = pbmode, pbdone' = pbdone,
    }

  // ---- the properties at the cell, and on the written cells ----
  // At the cell (evaluated by a run over the initializer's own row):
  pure def pbS2HoldsHere: bool = pbdesc == pbOracle(shCat(pbshape, pbform), pbsubj)
  pure def pbAbsorbHoldsHere: bool =
    pbdesc.forall(n => pbOwnUnion(shCat(pbshape, pbform), pbsubj).contains(n)
                       or admitFieldFree(shCat(pbshape, pbform), pbsubj).contains(n))
  // P-presence at the cell, stated for BOTH removals the writer-identity
  // rule enumerates:
  // dropping every writer-other entry changes nothing; dropping every
  // alien-key entry changes the description only by the block it carries (no
  // new name becomes describable - the property that holds on this walk).
  // P-presence (Part B) - MEASURED RED, a support instrument, not a gate.
  // On the faithful walk an alien entry IS the block that subtracts an own
  // claim (alien-copy: the walk serves {c}, drop B copy and it serves
  // {a,b,c}), and writer-removal deletes every fieldless entry (no writer to
  // match). The predicate states the sentence; its RED run is the evidence.
  pure def pbPresenceHoldsHere: bool =
    unionWalk(prunedOfAlien(shCat(pbshape, pbform), pbsubj), pbsubj)
      == unionWalk(shCat(pbshape, pbform), pbsubj)
    and unionWalk(prunedOfWriters(shCat(pbshape, pbform), pbsubj), pbsubj)
      == unionWalk(shCat(pbshape, pbform), pbsubj)
  pure def pbS1HoldsHere: bool =
    Cols.forall(n => verdictWalk(shCat(pbshape, pbform), pbsubj, n) != "malformed")
    and s1ShapeOk(pbshape, pbform)
    and (pbverdict == "err" or pbverdict == "defer" or pbverdict == "undescribed"
         or (pbverdict == "ok") == unionWalk(shCat(pbshape, pbform), pbsubj).contains(pbname))

  // The verify invariants: the bounded sweep re-checks the same expressions
  // over every cell the initializer writes, in both modes.
  //   P-S2 (Part B): the description IS the oracle's answer.
  val pbS2Neutrality = not(pbdone) or pbdesc == pbOracleDesc
  //   P-absorption (Part B): every described name is the record's own
  //   writer's claim, save the fieldless hand-off the absent-field rule
  //   names.
  val pbAbsorptionNever =
    not(pbdone)
    or pbdesc.forall(n => pbOwnUnion(shCat(pbshape, pbform), pbsubj).contains(n)
                           or admitFieldFree(shCat(pbshape, pbform), pbsubj).contains(n))
  //   P-presence (Part B): removing every alien-key entry changes no verdict.
  val pbPresenceNeverFlips = not(pbdone) or pbverdict == pbPrunedVerdict
  //   P-S1 (Part B): S1 = union.
  val pbS1Unions =
    not(pbdone)
    or(all {
      Cols.forall(n => verdictWalk(shCat(pbshape, pbform), pbsubj, n) != "malformed"),
      s1ShapeOk(pbshape, pbform),
      pbverdict == "err" or pbverdict == "defer" or pbverdict == "undescribed"
      or (pbverdict == "ok") == unionWalk(shCat(pbshape, pbform), pbsubj).contains(pbname),
    })

  // The runs: one per property, asserting on the initializer's own row.
  run pbS2 = {
    pbInit.expect(pbS2HoldsHere).then(pbStutter)
  }
  run pbAbsorption = {
    pbInit.expect(pbAbsorbHoldsHere).then(pbStutter)
  }
  run pbPresence = {
    pbInit.expect(pbPresenceHoldsHere).then(pbStutter)
  }
  run pbS1 = {
    pbInit.expect(pbS1HoldsHere).then(pbStutter)
  }

}
