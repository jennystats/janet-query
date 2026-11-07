// Catalogue lane, part B: the WRITER lane.
//
// Module: janetQueryCatalogue. The domain and writer
// rule, the same-path pair law, the present walk `unionPresent`, the pruned
// forms, the state, the rowless lane and every cm.* cell. The shape lane's
// vocabulary is imported from catalogue-shapes.qnt
// rather than restated. The three properties are Part B restatements
// against an independent oracle.
//
// RECURSION LIMIT (named): the oracle shares the walk's block rule and the
// fieldless predicate, so the properties instrument ADMISSION SHAPE
// changes, not an independent re-derivation of fieldless semantics. The
// independent anchor is the absent-mode baseline, pinned by the 2a cell and
// the cross-copy family.

module catalogueRecord {
  import catalogueShapes.* from "./catalogue-shapes"
  // the writer field's VALUE DOMAIN. Not every value names a record.
  //   wr-none   - the entry carries no writer field at all
  //   wr-A/wr-B - a name resolving to exactly one record (testimony)
  //   wr-two    - a name text resolving to TWO records: no testimony
  //   wr-nil, wr-false, wr-num, wr-tbl - values that are not record names
  //   wr-unres  - name text resolving to NO record

  // ---- domain ----
  // S1 = union: the refuse arm has no
  // state variable; union is the only behaviour, pinned by `gapUnionAdmits`.
  // the three key FORMS a name text answers to (variant expansion)
  // ---- the same-path pair law ----
  pure def ownCanon(r: str): str = if (r == "A") "C1" else "C2"
  pure def ownAddress(r: str): str = if (r == "A") "a1" else "a2"
  // THE ADDRESS BOOK: every spelling, and the owner(s) it names.
  // A spelling names exactly one record, or TWO - the second case is the
  // pair's shared path text, which is the alias-owner entry carrying both
  // ids under one spelling in the tree, never a shared own key.
  pure def ownedBy(text: str): Set[str] =
    if (text == "a1") Set("A")
    else if (text == "a2") Set("B")
    else if (text == "C1") Set("A", "B")
    else Set()
  // the SHARED text: a spelling owned by two records and by no single one
  pure def sharedTexts: Set[str] = Set("C1")
  // the pair's OWN KEYS, per owner. The catalogue
  // shapes do not read this; they read ownKeys below.
  pure def pairKeys(r: str): Set[str] =
    if (r == "A") Set("a1", "C1") else Set("a2", "C2")

  // the row the pair READS: the union of its own keys. The shared text is
  // NOT in it - a spelling two records carry describes neither.
  pure def sharedPathRow: Set[str] = Set("a1", "C1", "a2", "C2")
  // the pair's verdict, stated over the two owners' own keys
  pure def sharedPathVerdict(n: str): str =
    if (n == "a1") "serve"
    else if (n == "a2") "serve"
    else if (n == "C1") "refuse"
    else if (n == "C2") "serve"
    else "refuse"
  // (a) NO SHARED OWN KEY: stated as the two membership facts the law
  // needs. If the shared text were one record's own AND the other's, one
  // entry under it would describe both and a merge would
  // be reachable again.
  val samePathOwnersKeepDistinctKeys =
    not(sharedTexts.contains("a1")) and not(sharedTexts.contains("a2"))
  // (b) THE SHARED TEXT NAMES BOTH OWNERS AND IS NOBODY'S OWN KEY. The
  // measured tree's fact (:canons {1 "/d/v1" 2 "/d/v1"}, both ids on the
  // path spelling) is exactly this shape, and the law reads it as a
  // merge does: a text two records carry describes neither.
  val sharedTextIsOwnedByNeither =
    ownedBy("C1").size() == 2
    and sharedPathRow.contains("C1")
    and sharedPathVerdict("C1") == "refuse"

  // the column lists the shapes use
  // ---- the present-mode walk: FIELD SHAPE decides the rule ----
  // An entry whose value is not exactly one record name is FIELDLESS and
  // takes the absent-field walk unchanged - marking pass included: an
  // entry carrying the field is visible to the shared-block test, and the
  // testimony set that test consults is the record's own testifying
  // entries. An entry's list never blocks an entry under its own record's
  // own keys.
  // isFieldless tests the SHIPPED values only, so a mutant that reads a
  // non-`wr-none` value as testimony cannot pass by reporting every entry
  // fieldless - the strict reading only.
  pure def isFieldless(e: Ent): bool = e.writer.in(Set("", "wr-none", "wr-nil", "wr-false", "wr-num", "wr-tbl", "wr-unres", "wr-two"))
  // the TESTIMONY set: the record's own testifying entries - carried either
  // as a set of witnesses (catalogue) or as a set of column lists
  pure def txEntries(cat: Set[Ent], r: str): Set[Ent] =
    cat.filter(e => e.key.in(ownKeys(r)) and e.writer == r)
  pure def testimonyLists(cat: Set[Ent], r: str): Set[Set[str]] =
    txEntries(cat, r).map(e => e.cols)
  // B's block set: the lists an entry carries under a key alien to the
  // record (any key that is not one of the record's own - including
  // another record's own key)
  pure def entryLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => not(e.key.in(ownKeys(r)))).map(e => e.cols)
  // the absent-field walk on the catalogue: own spelling and no alien-key entry
  // carrying the list. (The record has one admission reading.)
  // A record's own testifying entry is never blocked by its own list: the
  // self-exclusion here made `aOf` empty for every testimony-bearing shape,
  // which gutted the absent-mode walk and left `prunedOfNonDescribing`
  // vacuous. Block evidence
  // is `entryLists` (alien keys) only; the testimony exclusion belongs to
  // `aOf30` once.
  pure def aOf(cat: Set[Ent], r: str): Set[Ent] =
    cat.filter(e => e.key.in(ownKeys(r))
                    and not(e.cols.in(entryLists(cat, r))))
               .filter(e => not(e.cols == Set()))
  // blocked by OWN VALUE: a fieldless entry blocks a fieldless peer's list
  // under the record's own keys (two fieldless copies - the value test)
  pure def blockedByOwnValue(cat: Set[Ent], r: str): bool =
    cat.filter(e => isFieldless(e)).exists(e =>
      cat.filter(o => isFieldless(o) and not(o.eid == e.eid)).exists(o => o.cols == e.cols))
  // TESTIMONY admission: the writer is this record. No
  // value-blindness here - the writer-identity walk. Two own entries with
  // the SAME list (own-agree) are both admitted: S1's union reading means
  // agreeing entries never block one another.
  pure def aOf30(cat: Set[Ent], r: str): Set[Ent] =
    aOf(cat, r).filter(e => not(e.cols == Set()))
  // an entry the absent-field walk accepts under its own value
  pure def absAccepts(cat: Set[Ent], r: str): Set[Ent] = aOf30(cat, r)
  // PRESENT-MODE ADMISSION: ONE condition for every entry - it sits under one of
  // the record's own spellings and no entry under an alien key carries its
  // list - plus the lane's identity term. A fieldless entry (a VALUE
  // test) is admitted by the walk alone; a writer-bearing entry only when
  // its writer is this record. `aOf` already states the key and
  // content conditions, so this def adds the lane split on top of it.
  pure def admittedPresent(cat: Set[Ent], r: str): Set[Ent] =
    aOf(cat, r).filter(e => isFieldless(e) or e.writer == r)
  pure def describedPresent(cat: Set[Ent], r: str): bool =
    admittedPresent(cat, r).exists(e => true)
  pure def unionPresent(cat: Set[Ent], r: str): Set[str] =
    admittedPresent(cat, r).map(e => e.cols).flatten()
  // the shape-stated adapter (an independent check):
  // SAME admission rule, fieldless membership decided by the VALUE'S SHAPE
  // rather than by the shipped-value list - the independence this check has
  // always had.
  pure def shapeFieldless(e: Ent): bool = not(e.writer.in(Set("wr-A", "wr-B")))
  pure def admittedPresentShape(cat: Set[Ent], r: str): Set[Ent] =
    aOf(cat, r).filter(e => shapeFieldless(e) or e.writer == r)
  pure def presentWalkAdapter(cat: Set[Ent], r: str, n: str, mode: str): str =
    if (mode == "absent") verdictOf(cat, r, n, mode)
    else if (admittedPresentShape(cat, r).exists(e => true))
      (if (n.in(admittedPresentShape(cat, r).map(e => e.cols).flatten())) "ok" else "err")
    else if (blockedByOwnValue(cat, r))
      "defer"
    else
      "undescribed"
  // the absent-field walk where a fieldless entry is blocked by an entry carrying
  // `wv` - the P-absorption comparison against fieldless entries' values
  pure def absBlockedAt(cat: Set[Ent], r: str, wv: str): bool =
    cat.filter(e => isFieldless(e)).exists(e =>
      cat.exists(o => not(o.key.in(ownKeys(r))) and o.writer == wv and not(e.key == o.key) and o.cols == e.cols))
  // the UNADJUDICATED lane: an arm the walk leaves undescribed
  // because a fieldless entry's OWN VALUE blocked it is NOT undescribed in
  // this lane - a testimony S1 trigger

  // ---- the two walks behind one interface ----
  pure def describedOf(cat: Set[Ent], r: str, mode: str): Set[str] =
    if (mode == "absent") unionAbsent(cat, r) else unionPresent(cat, r)

  // the present-mode shapes that witness the field sensitivity: a fieldless entry whose
  // own entry's list is in the record's testimony set (value-sensitive)
  pure def catFieldShapes(cat: Set[Ent], r: str): bool =
    cat.filter(e => isFieldless(e)).exists(e => e.cols.in(testimonyLists(cat, r)))
  pure def ffOwnWitness(cat: Set[Ent], r: str): bool =
    cat.filter(e => isFieldless(e)).exists(e => e.cols.in(testimonyLists(cat, r)))

  // whether a verdict is deferred is decided by whether a
  // describing entry is present, never by catalogue membership. An
  // undescribed arm is `undescribed`; no input reaches `defer` in the
  // contract's reading of the state.
  pure def verdictOf(cat: Set[Ent], r: str, n: str, mode: str): str =
    if (mode == "absent")
      (if (describedAbsent(cat, r)) (if (n.in(unionAbsent(cat, r))) "ok" else "err")
       // UNREACHABLE by construction: nothing pins it to defer
       else if (blockedByOwnValue(cat, r)) "defer"
       else "undescribed")
    else if (describedPresent(cat, r))
      (if (n.in(unionPresent(cat, r))) "ok" else "err")
    else if (blockedByOwnValue(cat, r))
      "defer"
    else
      "undescribed"


  // the two PRUNE forms the invariants compare against (independent of
  // the admission functions' internals, so a mutant of either side moves
  // the invariant):
  //   prunedOfWriters - every entry whose writer is NOT the record removed
  //   prunedOfAlien   - every entry under a key alien to the record removed
  pure def prunedOfWriters(cat: Set[Ent], r: str): Set[Ent] =
    cat.filter(e => e.writer == r)
  pure def prunedOfAlien(cat: Set[Ent], r: str): Set[Ent] =
    cat.filter(e => e.key.in(ownKeys(r)))
  //   prunedOfNonDescribing - every entry that describes NOTHING removed:
  //     aliens, foreign entries under the record's own keys, and fieldless
  //     entries the absent-field walk does not accept. If the story that
  //     cataloguedness decides defer-vs-refuse were the rule, removing
  //     these would move the verdict. Independent of `verdictOf`.
  pure def prunedOfNonDescribing(cat: Set[Ent], r: str, mode: str): Set[Ent] =
    if (mode == "absent") cat.filter(e => absAccepts(cat, r).contains(e))
    else cat.filter(e => admittedPresent(cat, r).contains(e))
  // ---- P-S2's INDEPENDENT ORACLE ----
  // The writer-identity rule, which is a NECESSARY condition: an entry
  // "contributes to a record's description only if its writer is that
  // record". Necessary is not sufficient. Admission follows the absent-field
  // walk's key scoping as well, stated here directly rather than by
  // calling the walk:
  //   (a) the entry's key is one of the record's OWN keys;
  //   (b) no alien-key entry carries the same list (the block rule);
  //   (c) the entry's writer RESOLVES to the record.
  // Stating (c) alone would over-read the
  // record and produces a false divergence.
  pure def ps2Names(w: str): Set[str] =
    if (w == "A") Set("A")
    else if (w == "B") Set("B")
    else if (w == "wr-A") Set("A")
    else if (w == "wr-B") Set("B")
    else Set()
  // (a) the record's own key texts, stated literally (keyOf is the model's
  //     own alphabet - restating it keeps the oracle independent of ownKeys)
  pure def ps2OwnKeyTexts(r: str): Set[str] =
    if (r == "A")
      Set("s:pa.parquet", "k:pa.parquet", "y:pa.parquet",
          "s:x", "k:x", "y:x")
    else
      Set("s:pb.parquet", "k:pb.parquet", "y:pb.parquet")
  // (b) the lists carried under keys the record does not own
  pure def ps2AlienLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => not(e.key.in(ps2OwnKeyTexts(r)))).map(e => e.cols)
  // (c) the writer condition
  pure def ps2WriterMatches(e: Ent, r: str): bool =
    ps2Names(e.writer).contains(r)
  pure def ps2Admitted(e: Ent, cat: Set[Ent], r: str): bool =
    e.key.in(ps2OwnKeyTexts(r))
    and not(e.cols.in(ps2AlienLists(cat, r)))
    and ps2WriterMatches(e, r)
  pure def ps2RecordLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => ps2OwnKeyTexts(r).contains(e.key)
                    and ps2Names(e.writer).size() > 0
                    and ps2Names(e.writer).contains(r)).map(e => e.cols)
  pure def ps2FieldlessAdmitted(e: Ent, cat: Set[Ent], r: str): bool =
    e.key.in(ps2OwnKeyTexts(r))
    and not(e.cols.in(ps2AlienLists(cat, r)))
    and e.cols.in(ps2RecordLists(cat, r))
  pure def ps2Oracle(cat: Set[Ent], r: str): Set[str] =
    cat.filter(e =>
        if (ps2Names(e.writer).size() > 0)
          ps2WriterMatches(e, r) and ps2Admitted(e, cat, r)
        else
          ps2FieldlessAdmitted(e, cat, r))
       .map(e => e.cols).flatten()

  // the record's own writer's claims (any key of its own)
  pure def ownWriterUnion(cat: Set[Ent], r: str): Set[str] =
    cat.filter(e => e.key.in(ownKeys(r)) and e.writer == r).map(e => e.cols).flatten()


  // ---- state ----
  var cmode: str
  var cform: str
  var cshape: str
  var csubj: str
  var cname: str
  var cverdict: str
  var cdesc: Set[str]
  var clane: str
  // what the selector's own PUBLISHED row holds
  // at that node - "pass-through" for a select that declares nothing (it
  // publishes the row beneath and no row of its own), "projection" for a
  // selector that declares a projection (it publishes exactly that, so a
  // refusal at it is a name a real row lacks)
  var cproj: str
  val ProjRows = Set("pass-through", "projection")
  // the row the select's own input hands on.
  var under: str
  // a FOURTH row state,
  // "undecidable" - the same-path pair's row. The described-union row decides:
  // carried names serve, unknown names refuse; it applies EXACTLY when every
  // arm's record is readable (the id-free catalogue read) and the identity
  // test cannot decide the owner, so the arm's own columns enter the row but
  // no entry can be attributed to one arm. A read-failed arm (no readable
  // record) is NOT this state: it stays "open" and defers.
  // "undecidable" is therefore membership, not blanket refusal - it reads
  // exactly as "row" does, and differs from "row" only in HOW the row came to
  // exist (a described union, not a decidable one).
  val UnderRows = Set("row", "open", "none", "undecidable")
  // the lane's two answers as the tree can
  // produce them. "answerable" is the lane finding a published-column
  // witness (`[:out :noproof]` in `query.janet`'s rowless lane), "silent"
  // is the lane finding none. Neither may decide a readable row's target.
  // "unproven" is the third answer - the target
  // lane's `:noproof`, a name the input's row CARRIES with no proof path
  // (reachable through a rename over a join arm). It is a
  // lane answer, not a row state, and like the other two it decides
  // nothing on a readable row.
  val Lanes = Set("answerable", "silent", "unproven")

  action init =
    nondet mode = Modes.oneOf();
    nondet form = Forms.oneOf();
    nondet shape = Shapes.oneOf();
    nondet subj = Records.oneOf();
    nondet name = Cols.oneOf();
    all {
      cmode' = mode,
      cform' = form,
      cshape' = shape,
      csubj' = subj,
      cname' = name,
      cverdict' = "none",
      cdesc' = Set(),
      clane' = "new",
      cproj' = "pass-through",
      under' = "row",
    }

  // the partitioned initializers the verify records use (one per mode)
  action initAbsent =
    nondet form = Forms.oneOf();
    nondet shape = Shapes.oneOf();
    nondet subj = Records.oneOf();
    nondet name = Cols.oneOf();
    all {
      cmode' = "absent",
      cform' = form,
      cshape' = shape,
      csubj' = subj,
      cname' = name,
      cverdict' = "none",
      cdesc' = Set(),
      clane' = "new",
      cproj' = "pass-through",
      under' = "row",
    }

  action initPresent =
    nondet form = Forms.oneOf();
    nondet shape = Shapes.oneOf();
    nondet subj = Records.oneOf();
    nondet name = Cols.oneOf();
    all {
      cmode' = "present",
      cform' = form,
      cshape' = shape,
      csubj' = subj,
      cname' = name,
      cverdict' = "none",
      cdesc' = Set(),
      clane' = "new",
      cproj' = "pass-through",
      under' = "row",
    }

  // write one configuration (the caller's catalogue and tree are free
  // parameters, exactly as `catalog`/`setArm` are in the reference model)
  action config(shape, form, subj, name, mode) =
    all {
      shape.in(Shapes),
      form.in(Forms),
      subj.in(Records),
      name.in(Cols),
      mode.in(Modes),
      clane == "new",
      cshape' = shape,
      cform' = form,
      csubj' = subj,
      cname' = name,
      cmode' = mode,
      cverdict' = cverdict,
      cdesc' = cdesc,
      clane' = clane,
      cproj' = cproj,
      under' = under,
    }

  // the row the select's input hands on. Write-only
  // while the node has not described (same frame rule as `setProjection`).
  action setUnder = {
    nondet u = UnderRows.oneOf();
    all {
      clane == "new",
      under' = u,
      cmode' = cmode, cform' = cform, cshape' = cshape,
      csubj' = csubj, cname' = cname, cverdict' = cverdict,
      cdesc' = cdesc, clane' = clane, cproj' = cproj,
    }
  }

  // the selector's published row is a free
  // parameter of the TREE, like the arm record. The FRAME it sits in is
  // fixed: a select that declares nothing publishes no row ("pass-through")
  // - the row beneath is the one an outer selector judges. A declared
  // projection carries its names; an EMPTY one is the CHAIN-LAUNDER the
  // reference model refuses at the outer selector, so no configuration of
  // this frame publishes it, and a refusal is read against a row
  // that exists
  action setProjection = {
    nondet p = ProjRows.oneOf();
    all {
      clane == "new",
      cproj' = p,
      under' = under,
      cmode' = cmode, cform' = cform, cshape' = cshape,
      csubj' = csubj, cname' = cname, cverdict' = cverdict,
      cdesc' = cdesc, clane' = clane,
    }
  }

  action describe =
    all {
      clane == "new",
      cdesc' = describedOf(shCat(cshape, cform), csubj, cmode),
      cverdict' = verdictOf(shCat(cshape, cform), csubj, cname, cmode),
      clane' = "done",
      cmode' = cmode,
      cform' = cform,
      cshape' = cshape,
      csubj' = csubj,
      cname' = cname,
      cproj' = cproj,
      under' = under,
    }

  action stutter = all {
    cmode' = cmode, cform' = cform, cshape' = cshape,
    csubj' = csubj, cname' = cname, cverdict' = cverdict, cdesc' = cdesc,
    clane' = clane, cproj' = cproj, under' = under,
  }

  action step = any { describe, setProjection, setUnder, stutter }


  val cataloguePresenceIsInert =
    all {
      // (a) an empty catalogue describes
      // nothing, so every name in both modes is UNDESCRIBED - never
      // deferred on membership, never described
      Set("absent", "present").forall(m =>
        Cols.forall(n =>
          verdictOf(shCat("empty", "s"), "A", n, m) == "undescribed")),
      // (b) the pruning fact: removing the entries that describe nothing
      // does not move the description or the verdict
      describedOf(shCat(cshape, cform), csubj, cmode)
        != describedOf(prunedOfNonDescribing(shCat(cshape, cform), csubj, cmode), csubj, cmode)
      or cverdict == "defer"
      or cverdict == verdictOf(prunedOfNonDescribing(shCat(cshape, cform), csubj, cmode), csubj, cname, cmode),
      // (c) the fieldless-writer walk agrees with the verdict,
      // or the arm is undescribed
      presentWalkAdapter(shCat(cshape, cform), csubj, cname, cmode) == cverdict
      or verdictOf(shCat(cshape, cform), csubj, cname, cmode) == "undescribed",
    }

  val catalogueNeverDecidesDeferral =
    clane != "done"
    or(cataloguePresenceIsInert)

  // a describe-nothing select's refusal
  // is against the PUBLISHED projection, never against the source row.
  //   (a) a select that declares no projection publishes no row of its own
  //       ("pass-through"): the row beneath is what an outer selector
  //       judges, so this node publishes no refusal at all - the source row
  //       is never the authority a pass-through refuses on;
  //   (b) a selector that declares a projection publishes exactly that row,
  //       so a refusal at it is a name a real published row lacks (the
  //       reference model's `projectionRefusalIsPublished`, boundary rule).
  // A refusal therefore exists only where a published row exists.
  //
  // The restatement reads what the property is actually about: a refusal is
  // LICENSED only where a published row exists, and a name is refused under
  // a published row only where that row exists and lacks the name. So a
  // pass-through licenses no refusal (there is no row of its own to lack
  // one), and a projection licenses refusal exactly of the names it lacks.
  //
  // Killed by M4 (projection-licenses-any, `targetRowVerdict`'s projection
  // reading widened to license every refusal): under a projection with a
  // published row, the mutant licenses refusing a name the row CARRIES, and
  // limb (b) reads that as a refusal with no missing name behind it.
  //
  // The target's verdict through a declared projection: the boundary rule,
  // stated once so both the property and its cells read the same expression.
  pure def targetThroughProjection(p: str, n: str, pub: Set[str], walk: str): str =
    if (p == "projection") (if (pub.contains(n) and walk == "ok") "serve" else "refuse")
    else (if (walk == "ok") "serve" else "refuse")
  def projectionRefusalIsLicensed =
    clane != "done" or(
      (cproj == "pass-through"
       implies not(Cols.forall(n => targetThroughProjection(cproj, n, cdesc, "ok") == "refuse")))
      and
      (cproj == "projection"
       implies Cols.forall(n =>
                 (targetThroughProjection(cproj, n, cdesc, "ok") == "refuse")
                 == not(cdesc.contains(n)))))

  // THE SELECT-TARGET CEILING. A select's TARGET
  // rows are judged at the node, against the ROW ITS INPUT HANDS ON. They
  // are never judged against the row the select PUBLISHES (that row is the
  // outer selector's business) and never against the arm's stored source
  // row. The bound is the published-projection boundary read at
  // the node that makes the reference, under the
  // deferral-independence rule.
  //
  // The three states of the row beneath, and what each does to a target:
  //   "row"  - the input publishes a row. The row is the boundary: a name
  //            it carries is SERVED, a name it lacks is REFUSED, and no
  //            projection above the node and no catalogue configuration
  //            changes that.
  //   "open" - the input publishes a row nobody can decide (an unnamed arm
  //            beneath it). The target DEFERS: a select never refuses on a
  //            row it cannot read (a false refusal).
  //   "none" - the input has no determinable scope (an uncatalogued base,
  //            no description anywhere). The engine is the oracle: the
  //            target DEFERS, and no catalogue state settles it.
  //
  // The three-state table this property states, with the measured
  // rows the model reads from it:
  //   base      PASS  - the select served :z under a rule that read the
  //                     inner row as the supplier
  //   N-F1      FAIL  - 1059: the outer group's key list served :sum_pay
  //                     out of the outer group's own row
  //   N-F1+D1   FAIL  - 2103: a select over an arm whose row lacks :z
  //                     SERVED it (the N-F1 fix moved what the arm
  //                     publishes and the ceiling stopped refusing)
  //
  // The row-mode verdict is a PURE function of (row state, name, row
  // contents). It takes no state variable, so the property is inductive
  // without an extra guard: no step can change what it asserts.
  pure def targetRowVerdict(row: str, name: str, published: Set[str]): str =
    if (row == "row" or row == "undecidable") (if (published.contains(name)) "serve" else "refuse") else "defer"

  //   (a) THE CEILING. On a published row the verdict is exactly the row's
  //       membership; an open row and a rowless scope defer. Nothing else is
  //       read.
  val targetCeilingIsTheRow =
    clane != "done"
    or(UnderRows.forall(u =>
         Cols.forall(n =>
           targetRowVerdict(u, n, cdesc)
           == (if (u == "row" or u == "undecidable")
                 (if (cdesc.contains(n)) "serve" else "refuse")
               else "defer"))))
  //   (b) NO CATALOGUE CONFIGURATION RESCUES A TARGET, and none refuses one
  //       either. Stated on a row that exists (limb (a) owns the open and
  //       rowless states, which defer under every catalogue). The row's
  //       verdict is membership, so the catalogue's own description and the
  //       row-mode serve agree over every shape and form: a name every
  //       configuration describes is served by every configuration that
  //       describes it, and a name none describes is refused by all of them.
  val targetCeilingIsCatalogueIndependent =
    clane != "done"
    or(Cols.forall(n =>
         (Shapes.forall(s =>
            Forms.forall(f =>
              describedOf(shCat(s, f), csubj, cmode).contains(n)))
          == (Shapes.forall(s =>
                Forms.forall(f =>
                  targetRowVerdict("row", n, describedOf(shCat(s, f), csubj, cmode)) == "serve"))))))

  //   (c) THE PUBLISHED ROW NEVER DECIDES A TARGET, the 1059 shape. The
  //       verdict reads the row beneath (`under`) and `cdesc`; `cproj` is
  //       the row this node PUBLISHES, which is the outer selector's
  //       business and must never enter the target's verdict.
  //
  //       the limb must reach the code's real quantity, and the
  //       code's verdict vocabulary (serve/refuse/defer) is NOT the
  //       catalogue walk's (ok/err/defer/undescribed). Defining the target
  //       verdict here as a function of the ROW ALONE can only ever restate
  //       `targetRowVerdict`, in any direction a row-mode
  //       predicate can take.
  //
  //       So the limb is stated in the walk's own vocabulary, over the
  //       catalogue the module actually grades with: a declared projection
  //       is a REFUSAL BOUNDARY (contract, boundary rule). A name the
  //       boundary carries is admitted only where the walk
  //       would serve it regardless of the boundary (`ok`); a name the
  //       boundary lacks is never rescued by it. A mutant whose
  //       serve is whatever the published row holds - violates the first
  //       clause wherever the walk refuses a name the boundary leaks.
  //
  //       LIMIT (measured): the clause is one-directional.
  //       The symmetric form ("the boundary never moves a verdict") is false
  //       in the model by construction, because a DECLARED-EMPTY projection
  //       is a real published row and refuses where the bare walk refuses
  //       anyway - an equality over it is the vacuity the original limb
  //       was. The one-directional clause is what the mutant breaks.
  //
  // The target's verdict through a declared projection needs
  // a limb below (b) because Quint resolves no forward references.
  val targetCeilingIgnoresPublishedRow =
    clane != "done"
    or(Cols.forall(n =>
         ProjRows.forall(p =>
           Shapes.forall(s =>
             targetThroughProjection(p, n, describedOf(shCat(s, "s"), csubj, cmode),
                                     verdictOf(shCat(s, "s"), csubj, n, cmode)) == "serve"
             implies verdictOf(shCat(s, "s"), csubj, n, cmode) == "ok"))))

  // the one property the verify record names (the three limbs conjoined;
  // the gate verifies the limbs SOLO, per the per-conjunct isolation rule)
  val selectTargetCeiling =
    all {
      targetCeilingIsTheRow,
      targetCeilingIsCatalogueIndependent,
      targetCeilingIgnoresPublishedRow,
    }

  // P-S2 (shared-block neutrality; Part B restatement). The record's description
  // IS the oracle's answer - the writer-identity rule on its own alphabet: (c) the
  // writer resolves to the record (NECESSARY), (a) the entry sits under
  // one of the record's own spellings, (b) no alien-key entry carries
  // its list. Absent mode keeps its refutation; the present-mode run is a
  // support instrument, red on the `ff-*` shapes through a fixture defect.
  val ps2Neutrality =
    clane != "done"
    or(cdesc == ps2Oracle(shCat(cshape, cform), csubj))

  // P-absorption (the wall, closed form; Part B restatement). Nothing outside
  // the record's own writer's claims is described (the walk's fieldless lane
  // is the absent-field hand-off; P-S2 compares that against its own
  // statement of the same rule).
  val absorptionNever =
    clane != "done"
    or(cdesc.forall(n => n.in(ownWriterUnion(shCat(cshape, cform), csubj))))

  // P-presence (never flips a verdict; Part B restatement). Removing
  // every entry under a key alien to the record changes no verdict.
  val presenceNeverFlips =
    clane != "done"
    or(cverdict == verdictOf(prunedOfAlien(shCat(cshape, cform), csubj), csubj,
                             cname, cmode))
  // P-ROWLESS (THE ROWLESS LANE OWNS NOTHING ON A READABLE
  // ROW). The target clause it would otherwise state is unreachable in the
  // tree, and the reference falls instead
  // to the rowless lane, which reads the input's published-lane state and
  // never the row the select hands on. The defect that lane produces is
  // the smoke cell a select over an arm whose
  // row lacks the target serves the name.
  //
  // The contract is the law (the false-refusal rule
  // bounds a deferral; readability, not catalogue membership, decides a
  // verdict). Restated as one sentence: when the input's row is READABLE,
  // the rowless lane may not answer for the target at all - the verdict is
  // the row's membership, and a name the row lacks is REFUSED. The lane is
  // authoritative only where no row exists (`none`) or the row cannot be
  // read (`open`), and there its answer is the deferral the contract
  // licenses.
  //
  // Prose does not verify. The property is falsifiable by three mutants,
  // each a one-line change at the site the code fix will touch, and each
  // named beside the conjunct it must die on:
  //   M1 rowless-serves  - the lane returns "serve" for every row state
  //                        (the unchecked `[:out :noproof]` index)
  //                        (the over-refusal the false-refusal rule forbids)
  //   M3 rowless-vacuous - the lane returns "defer" for every row state
  //                        (the vacuous second reading of the
  //                        false-refusal rule: nothing is ever refused)
  // All three die on the readable limb, because on a readable row the
  // lane's authority is empty: no lane answer reaches the verdict, so any
  // lane answer is measured against the row and the row alone.
  // ...except the described-union row ("undecidable"): it is a row
  // like any other, so it decides by membership - a carried name serves, an
  // unknown name refuses. It is grouped with "row" deliberately: the state
  // name records how the row was established, not a different verdict.
  pure def rowlessLaneVerdict(lane: str, row: str, name: str, published: Set[str]): str =
    if (row == "row" or row == "undecidable") (if (published.contains(name)) "serve" else "refuse")
    else if (row == "open") "defer"
    else if (lane == "answerable") "defer"
    else if (lane == "unproven") "defer"
    else "defer"
  //   (c') THE LANE DEFERS, and it defers for the UNPROVEN answer too. The
  //       third lane answer is reachable, so a ceiling
  //       that treats `:noproof` as a refusal at the lane (a candidate
  //       measured red) writes "refuse" here and dies; so does a ceiling
  //       that reads the lane as authoritative anywhere but the rest.
  val rowlessLaneDefersEveryAnswer =
    clane != "done"
    or(Lanes.forall(l =>
         Cols.forall(n =>
           rowlessLaneVerdict(l, "none", n, cdesc) == "defer")))
  //   (a) THE READABLE ROW. The lane's answer is not an argument. Every
  //       name on a readable row gets the row's membership verdict, so the
  //       property is blind to the lane: M1, M2 and M3 all write a
  //       different answer here and none of them survives.
  val rowlessLaneCannotServeOnARow =
    clane != "done"
    or(Lanes.forall(l =>
         Cols.forall(n =>
           rowlessLaneVerdict(l, "row", n, cdesc)
           == (if (cdesc.contains(n)) "serve" else "refuse"))))
  //   (b) THE UNREADABLE INPUT. Where the row cannot be read, the lane is
  //       the licensed oracle and its answer is the deferral - a name
  //       neither served nor refused. This limb is what keeps the property
  //       from being satisfied by a ceiling that refuses everything (M2).
  val rowlessLaneDefersWithoutARow =
    clane != "done"
    or(Lanes.forall(l =>
         Cols.forall(n =>
           rowlessLaneVerdict(l, "open", n, cdesc) == "defer"
           and rowlessLaneVerdict(l, "none", n, cdesc) == "defer")))
  //   (c) THE LANE NEVER MOVES A ROW VERDICT, in the concrete shape the
  //       code defect takes: a select whose target names a COLLECTION KEY
  //       (an unnamed join key) over a readable row that does not carry
  //       it. That is the defect cell's tuple, and the contract's answer is
  //       refusal - the same answer as for any other row-lacking name.
  //       Stated separately because it is the only lane tuple the tree
  //       reaches, so it is the one a regression cell can pin.
  val rowlessKeyTargetStillRefuses =
    clane != "done"
    or(Cols.forall(n =>
         cdesc.contains(n) or rowlessLaneVerdict("answerable", "row", n, cdesc) == "refuse"))

  // P-PRESENCE (deferral independence): the catalogue
  // never decides defer-vs-refuse. The state a walk lands in is a function
  // of what the entries SAY, never of whether a catalogue exists: an arm no
  // entry describes lands UNDESCRIBED (the one exception, a blocked
  // fieldless pair, is the shared block itself, and it is `defer` in both
  // modes whatever the catalogue's membership).
  //
  // The property states the contraction directly:
  // EMPTY CATALOGUE, ANY NAME, UNDESCRIBED - so a mutant that defers while
  // entries exist and describes on an empty one writes a different state
  // in exactly that case and dies. Pruning
  // only removes entries that describe nothing, so on every shape where the
  // two walks agree the pruned catalogue IS the empty-contraction case, and
  // `cmVacuousCatalogueUndescribed` states it as a cell.
  // A non-describing entry is verdict-inert where it does not move the union.
  //
  // `cataloguePresenceIsInert` carries (a) the empty-catalogue statement,
  // (b) the pruning comparison, (c) the writer-state limb - ONE property
  // carries the deferral-independence duty on both of its faces. Any limb
  // failing refutes it.

  // P-GAP (the permanent limitation, S1 = union):
  // two disagreeing own entries are UNIONED - the union serves every name a
  // describing entry carries. What the GAP does NOT guarantee is that
  // either entry was the schema; the union is not a schema report. An empty
  // union means an undescribed arm (never `ok`/`err`); the verdict never
  // invents a described arm.
  //
  // SCOPE of the per-entry invariance below (measured, each a counterexample
  // found by verify): removing an entry moves a verdict in exactly three
  // certified ways - an ALIEN entry carries the block (removing it
  // unblocks), a DESCRIBING entry carries union columns (removing it
  // narrows the union), and a `defer` is a PAIR (removing either member
  // resolves it). The invariance therefore ranges over entries that are
  // none of those.
  val gapUnionAdmits =
    clane != "done"
    or(and {
      // A served name is carried by the union (the union is what serves).
      cverdict != "ok" or describedOf(shCat(cshape, cform), csubj, cmode).contains(cname),
      // An empty union never serves or refuses.
      describedOf(shCat(cshape, cform), csubj, cmode) != Set()
        or cverdict == "undescribed" or cverdict == "defer",
      // Non-blocking, non-describing entries are verdict-inert.
      shCat(cshape, cform).forall(e =>
        not(e.cols.in(entryLists(shCat(cshape, cform), csubj)))
        and not(prunedOfNonDescribing(shCat(cshape, cform), csubj, cmode).contains(e))
        and cverdict != "defer"
        implies
        cverdict == verdictOf(shCat(cshape, cform).exclude(Set(e)), csubj, cname, cmode)),
    })

  // P-FW: writer testimony holds only when the value
  // resolves to EXACTLY ONE record. A name resolving to two records, and
  // every non-name value, is fieldless - the absent-field rule governs it
  // as if the field were absent, marking pass included.
  val fieldlessWriterSemantics =
    clane != "done"
    or(presentWalkAdapter(shCat(cshape, cform), csubj, cname, cmode) == cverdict)
    or(verdictOf(shCat(cshape, cform), csubj, cname, cmode) == "undescribed")

  // P-FWD (the value domain): the fieldless test agrees with the value
  // SHAPE. `isFieldless` is the membership the walk reads; `shapeFieldless`
  // is the rule's sentence ("not exactly one record name"). Laboratory and
  // sentence must name the same entries - a value the sentence calls
  // fieldless (`wr-unres`, `wr-two`, every non-name) that the walk treats
  // as testimony loses the claim, and this is what catches a writer value
  // reclassified out of the fieldless set.
  val fieldlessDomainAgrees =
    clane != "done"
    or(Set("ff-own", "ff-peer-none", "ff-peer-nil", "ff-peer-false", "ff-two-own",
           "ff-none-elsewhere", "ff-nil-elsewhere", "ff-two-elsewhere",
           "ff-blocked", "ff-mixed", "ff-unres").forall(s =>
         shCat(s, cform).forall(e => isFieldless(e) == shapeFieldless(e))))

  // P-absorption against each FIELDLESS entry's OWN VALUE: no fieldless
  // entry changes a verdict by contributing under the value it carries.
  // Absent: REFUTED - the field-sensitivity differential
  // as its own
  // property (a fieldless entry whose value meets another entry's list
  // under the record's own keys moves the verdict).
  val fieldlessOwnValueInert =
    clane != "done"
    or(cmode != "absent")
    or(not(catFieldShapes(shCat(cshape, cform), csubj)))
    or(cverdict == verdictOf(shCat(cshape, cform), csubj, cname, cmode))

  // F-F1 (informational): on an
  // entry carrying the writer field, the field SHAPE decides the rule. An
  // entry whose value is not a record name is fieldless BY RULE and takes
  // the absent-field walk even where its OWN value would be contradicted. The
  // six shapes below witness the value-sensitivity of the absent-field walk
  // (`usable`/`describedAbsent` depend on any value) - every observed
  // counterexample lives there. The refutation is stated, not disposed.
  val fieldShapeDecidesRule =
    clane != "done"
    or(cmode != "present")
    or(not(catFieldShapes(shCat(cshape, cform), csubj)))

  // P-S1, absent limb: the field semantics UNION two
  // disagreeing own entries (measured), and never refuse the arm as
  // duplicate-schema - a described arm serves the union, nothing is
  // malformed. `malformed` is unreachable in both modes (S1 = union).
  val absentFieldUnions =
    clane != "done"
    or(cmode != "absent")
    or(not(describedAbsent(shCat(cshape, cform), csubj)))
    or((cverdict == "ok") == cname.in(unionAbsent(shCat(cshape, cform), csubj)))

  // ---- protocol runs -------------------------------------------------------
  // SELECTION: `quint test --match='cm.*'` (the reference model's selectors
  // cr*/cr1x are untouched). No run is named after its own subject, and no
  // helper here reads state (see the instrument note in the reference
  // model's header).
  //
  // ABSENT-MODE BYTE-FAITHFULNESS: every expected value below was measured
  // at a fresh process against an engine worktree carrying no writer field;
  // a model/tree disagreement is a finding, and none was found.

  // the alien agreeing copy
  // subtracts the arm's own entry's claim - described {c}, select :a
  // refused. Measured: source-columns (c); err unknown-column:a
  run cmAlienCopySubtractsOwn = {
    init
      .then(config("alien-copy", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set("c") and cverdict == "err")
      .then(stutter)
  }

  // the same shape, the surviving own list: select :c serves
  run cmAlienCopyOtherNameServes = {
    init
      .then(config("alien-copy", "s", "A", "c", "absent"))
      .then(describe)
      .expect(cverdict == "ok")
      .then(stutter)
  }

  // the pruned catalogue (the alien copy removed) describes the union:
  // measured (a b c). This is P-S2's absent-mode refutation as a cell
  run cmPrunedDescribesTheUnion = {
    init
      .expect(describedOf(prunedOfWriters(shCat("alien-copy", "s"), "A"), "A", "absent")
              == Set("a", "b", "c"))
      .then(stutter)
  }

  // the lone block describes nothing: measured source-columns
  // nil, the arm unnamed - the select DEFERS to the engine oracle. The
  // model's name for that state is `undescribed`.
  run cmLoneBlockDescribesNothing = {
    init
      .then(config("lone-block", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // THE WALL, both spellings: an entry under one
  // of the arm's own keys, written by the other record, DESCRIBES the arm
  // in absent mode. Measured: (y z) under the path key and under the alias
  // key. This is P-absorption's absent-mode refutation as a cell
  run cmWallPathDescribes = {
    init
      .then(config("wall-path", "s", "A", "y", "absent"))
      .then(describe)
      .expect(cdesc == Set("y", "z") and cverdict == "ok")
      .then(stutter)
  }

  run cmWallAliasDescribes = {
    init
      .then(config("wall-alias", "s", "A", "y", "absent"))
      .then(describe)
      .expect(cdesc == Set("y", "z") and cverdict == "ok")
      .then(stutter)
  }

  // the wall's spelling breadth: every form of the arm's own
  // spellings reaches the arm - string, keyword and symbol alike
  run cmWallFormBreadth = {
    init
      .expect(Forms.forall(f =>
        describedOf(shCat("wall-alias", f), "A", "absent") == Set("y", "z")
        and describedOf(shCat("wall-path", f), "A", "absent") == Set("y", "z")))
      .then(stutter)
  }

  // in-list duplicates de-duplicate: measured (a b q)
  run cmDuplicateListDedups = {
    init
      .then(config("own-dup", "s", "A", "q", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b", "q") and cverdict == "ok")
      .then(stutter)
  }

  // disagreeing own entries union: measured (a b c d) - alias [a b], path [c d]
  run cmDisagreeingOwnUnions = {
    init
      .then(config("own-disagree", "s", "A", "c", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b", "c", "d") and cverdict == "ok")
      .then(stutter)
  }

  // the S1 shape: measured (x y z), select :z serves -
  // the silent union the union gap records
  run cmS1FieldShapeUnions = {
    init
      .then(config("s1-shape", "s", "A", "z", "absent"))
      .then(describe)
      .expect(cdesc == Set("x", "y", "z") and cverdict == "ok")
      .then(stutter)
  }

  // an alien entry with a DIFFERENT list subtracts nothing (the control):
  // described (a b)
  run cmAlienOtherListInert = {
    init
      .then(config("alien-other", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b") and cverdict == "ok")
      .then(stutter)
  }

  // two own spellings carrying one list: catalogued twice, not a block
  run cmOwnSpellingsAgree = {
    init
      .then(config("own-agree", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b") and cverdict == "ok")
      .then(stutter)
  }

  // overlapping own entries: measured (a b c)
  run cmOwnOverlapUnions = {
    init
      .then(config("own-overlap", "s", "A", "c", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b", "c"))
      .then(stutter)
  }

  // no entry at all: the arm is unnamed, every name defers to the oracle -
  // the state is `undescribed`
  run cmAbsentCatalogueDefers = {
    init
      .then(config("empty", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // a CROSS-RECORD copy subtracts too (the "any key" limb,
  // measured: nil): B's own path entry carrying A's list silences A's
  // own entry. The state is `undescribed` (a bare arm no admitted
  // entry describes), NOT `defer`
  run cmCrossRecordCopySilences = {
    init
      .then(config("cross-copy", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // agreeing own pair + alien copy (measured: nil - BOTH own entries are
  // silenced, the arm unnamed, the oracle serves): the strongest shape of
  // the absent-mode subtraction
  run cmAgreeCopySilencesBoth = {
    init
      .then(config("agree-copy", "s", "A", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // the cross-record subtraction is SYMMETRIC (measured: B under the
  // same catalogue is nil - A's alias entry silences B's own entry as
  // much as B's silences A's; both records lose their claim, the one
  // shape where every entry is unusable for both subjects)
  run cmRecordBSilencedByCrossCopy = {
    init
      .then(config("cross-copy", "s", "B", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // B described by its own entry alone (measured: (a b)) - the sanity
  // lane that the cross-copy silence above is the copy, not B's lane
  run cmRecordBDescribesOwn = {
    init
      .then(config("b-own", "s", "B", "a", "absent"))
      .then(describe)
      .expect(cdesc == Set("a", "b") and cverdict == "ok")
      .then(stutter)
  }

  // the variant-expansion form-invariance: the own entry
  // read through every key form gives one description
  run cmFormInvarianceOwnEntry = {
    init
      .expect(Forms.forall(f =>
        describedOf(shCat("own-agree", f), "A", "absent") == Set("a", "b")))
      .then(stutter)
  }

  // ---- present-mode runs (identity-scoped admission) ----

  // the alien copy CARRIES the record's own list {a,b}, so the content rule
  // silences the own entry claiming it; the arm is described by its other
  // own entry ({c}). An alien copy neither adds nor subtracts a
  // name, and it does silence the claim it duplicates.
  run cmPresentAlienCopySilencesTheCopiedList = {
    init
      .then(config("alien-copy", "s", "A", "a", "present"))
      .then(describe)
      .expect(cdesc == Set("c") and cverdict == "err")
      .then(stutter)
  }

  // a shared block describes nothing: no own-writer entry, the arm
  // unnamed, the oracle defers - the state is `undescribed`
  run cmPresentSharedBlockInert = {
    init
      .then(config("lone-block", "s", "A", "a", "present"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // THE WALL CLOSED: the same foreign entry that described the arm in
  // absent mode contributes nothing here
  run cmPresentWallClosed = {
    init
      .then(config("wall-path", "s", "A", "y", "present"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // the wall closed under EVERY key form (the spelling breadth, closed)
  run cmPresentWallClosedAllForms = {
    init
      .expect(Forms.forall(f =>
        describedOf(shCat("wall-alias", f), "A", "present") == Set()
        and describedOf(shCat("wall-path", f), "A", "present") == Set()))
      .then(stutter)
  }

  // P-S1, the refuse reading REFUTED: two own-writer entries with different
  // sets do NOT refuse the arm as duplicate-schema malformed. The arm is
  // described and the target serves - union is the behaviour.
  run cmPresentS1Refuses = {
    init
      .then(config("s1-shape", "s", "A", "z", "present"))
      .then(describe)
      .expect(cdesc == Set("x", "y", "z") and cverdict == "ok")
      .then(stutter)
  }

  // the same shape UNIONS: S1 = union,
  // `malformed` is unreachable (the permanent union gap). The name is kept
  // as the union pin so a mutant restoring the refuse choice has a cell to
  // fail.
  run cmGapUnionServesDisagreeingOwn = {
    init
      .then(config("s1-shape", "s", "A", "z", "present"))
      .then(describe)
      .expect(cdesc == Set("x", "y", "z") and cverdict == "ok")
      .then(stutter)
  }

  // P-S1, the union choice: the same shape serves the union - the
  // absent-field semantics carried forward under identity scoping
  run cmPresentS1Unions = {
    init
      .then(config("s1-shape", "s", "A", "z", "present"))
      .then(describe)
      .expect(cdesc == Set("x", "y", "z") and cverdict == "ok")
      .then(stutter)
  }

  // agreeing own pair + a copy carrying the same list: the block silences
  // BOTH own entries, so the arm is undescribed (the narrowed-C reading)
  run cmPresentAgreeCopySilenced = {
    init
      .then(config("agree-copy", "s", "A", "a", "present"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // B's own path entry carries A's list under a key ALIEN to A: the content
  // rule
  // silences A's only claim and the arm is undescribed (absent mode already
  // silences it - cmCrossRecordCopySilences)
  run cmPresentCrossCopySilences = {
    init
      .then(config("cross-copy", "s", "A", "a", "present"))
      .then(describe)
      .expect(cdesc == Set() and cverdict == "undescribed")
      .then(stutter)
  }

  // absent mode never refuses an arm as duplicate-schema (the field
  // semantics union - S1's absent limb, quantified over the whole space)
  run cmAbsentNeverMalformed = {
    init
      .expect(Shapes.forall(s =>
        Forms.forall(f =>
          Records.forall(r =>
            Cols.forall(n =>
              not(verdictOf(shCat(s, f), r, n, "absent") == "malformed"))))))
      .then(stutter)
  }

  // the deferral-independence differential as cells: an entry that
  // DESCRIBES NOTHING moves a
  // bare arm's where-lane verdict from defer to `err unknown-column`.
  // model's verdict for the arm is UNDESCRIBED in both the clean and the
  // vacuous case, and `catalogueNeverDecidesDeferral` is the property.
  run cmVacuousCatalogueUndescribed = {
    init
      .expect(
        Set("empty", "lone-block", "cross-copy").forall(s =>
          verdictOf(shCat(s, "s"), "A", "a", "absent") == "undescribed"
          and verdictOf(prunedOfNonDescribing(shCat(s, "s"), "A", "absent"), "A", "a", "absent")
              == "undescribed"))
      .then(stutter)
  }

  // A1 on the wall: in PRESENT mode the wall is closed and the arm is
  // undescribed (both entries are fieldless here - the base fixtures)
  run cmVacuousClosedWallAliased = {
    init
      .expect(verdictOf(shCat("wall-alias", "s"), "A", "z", "present") == "undescribed")
      .then(stutter)
  }

  // `malformed` is unreachable in BOTH modes (S1 = union)
  run cmNeverMalformed = {
    init
      .expect(Modes.forall(m =>
        Shapes.forall(s =>
          Forms.forall(f =>
            Records.forall(r =>
              Cols.forall(n =>
                not(verdictOf(shCat(s, f), r, n, m) == "malformed")))))))
      .then(stutter)
  }

  // a testimony writer describes its arm
  run cmFieldlessWriteTestimonyDescribes = {
    init
      .then(config("ff-own", "s", "A", "a", "present"))
      .then(describe)
      .expect(cdesc == Set("a", "b") and cverdict == "ok")
      .then(stutter)
  }

  // a value that is not exactly one record name is
  // fieldless. Measured, three distinct outcomes:
  //   ff-peer-none    - a NAME for another record: present refuses it,
  //                     absent is value-blind and admits it -> the two
  //                     modes DIVERGE (this is the field-sensitivity differential)
  //   ff-peer-nil / -false / ff-two-own - not a name, and the arm's only
  //                     entry, so nothing blocks it: both modes ok
  //   *-elsewhere     - a stranger carries the same list, which is the
  //                     shared-block evidence: `defer` in BOTH modes
  // The UNRESOLVABLE name is absent from this set: with no other entry
  // carrying its list it is admitted (cmUnresolvableWriterAdmitsAsFieldless).
  run cmFieldlessUnresolvableIsFieldless = {
    init
      .expect(
        describedOf(shCat("ff-peer-none", "s"), "A", "present") == Set()
        and verdictOf(shCat("ff-peer-none", "s"), "A", "a", "present") == "undescribed"
        and verdictOf(shCat("ff-peer-none", "s"), "A", "a", "absent") == "ok"
        and Set("ff-peer-nil", "ff-peer-false", "ff-two-own").forall(s =>
          describedOf(shCat(s, "s"), "A", "present") == Set("a", "b")
          and verdictOf(shCat(s, "s"), "A", "a", "present") == "ok"
          and verdictOf(shCat(s, "s"), "A", "a", "absent") == "ok")
        and Set("ff-none-elsewhere", "ff-nil-elsewhere", "ff-two-elsewhere").forall(s =>
          describedOf(shCat(s, "s"), "A", "present") == Set()
          and verdictOf(shCat(s, "s"), "A", "a", "present") == "defer"
          and verdictOf(shCat(s, "s"), "A", "a", "present") == verdictOf(shCat(s, "s"), "A", "a", "absent")))
      .then(stutter)
  }

  // the unresolvable-name SIBLING ("naming nothing"): the entry is
  // the arm's only claim and no other entry carries its list, so the
  // absent-field rule
  // ADMITS it - fieldless, the claim survives. Reading the unresolvable
  // name as testimony would refuse it (the unresolvable-writer mutant).
  run cmUnresolvableWriterAdmitsAsFieldless = {
    init
      .expect(
        describedOf(shFfCat("wr-unres", false), "A", "present") == Set("a", "b")
        and verdictOf(shFfCat("wr-unres", false), "A", "a", "present") == "ok"
        and verdictOf(shFfCat("wr-unres", false), "A", "q", "present") == "err")
      .then(stutter)
  }

  // a fieldless entry blocked by a stranger carrying the
  // same NON-NAME value is stranded by its OWN value (the absent-field walk
  // marks the block) - that stranded state is `defer`; with no
  // stranger the same entry is admitted
  run cmNoFieldValueSensitive = {
    init
      .expect(verdictOf(shFfCat("wr-none", true), "A", "a", "present") == "defer"
              and verdictOf(shFfCat("wr-none", false), "A", "a", "present") == "ok")
  }

  // the stranger: the contradicted value from OUTSIDE the arm's keys
  // is what tells none (ignored) from a record name
  run cmNoFieldElsewhereInerts = {
    init
      .expect(verdictOf(shFfCat("wr-none", false), "A", "a", "present") == "ok"
              and verdictOf(shFfCat("wr-B", false), "A", "a", "present") == "undescribed")
      .then(stutter)
  }

  // the shape set is exactly the enumerated list (guards silent drift of
  // the coverage claim)
  run cmShapesEnumerated = {
    init
      .expect(Shapes == Set("empty", "own-agree", "own-disagree", "s1-shape",
                            "own-dup", "own-overlap", "alien-copy", "alien-other",
                            "lone-block", "wall-path", "wall-alias", "cross-copy",
                            "agree-copy", "b-own",
                            // the two-key disagreement member
                            "own-subset",
                            "ff-own", "ff-peer-none", "ff-peer-nil", "ff-peer-false",
                            "ff-two-own", "ff-none-elsewhere", "ff-nil-elsewhere",
                            "ff-two-elsewhere", "ff-blocked", "ff-mixed", "ff-unres"))
      .then(stutter)
  }

  // THE TWO-KEY DISAGREEMENT: A described at both its keys with
  // the second a strict subset of the first. The union over A's own keys
  // admits everything either key describes, so `:a` (in the alias list
  // only) is described, and `:b` is described by both. This is the serve
  // the tree performs and the model had no member to state.
  run cmOwnSubsetUnionAdmits = {
    init
      .expect(
        Forms.forall(f =>
          describedOf(shCat("own-subset", f), "A", "present").contains("a")
          and describedOf(shCat("own-subset", f), "A", "present").contains("b")))
      .then(stutter)
  }
  // the shape set PARTITIONS: the fourteen base fixtures carry the
  // base value domain only (testimony or no field), the field shapes cover
  // every other writer value
  run cmShapePartition = {
    init
      .expect(Shapes.forall(s =>
        not(BaseShapes.contains(s))
        or shCat(s, "s").forall(e => V30Vals.contains(e.writer))))
      .then(stutter)
  }

  // the absent-field walk is value-sensitive: the four ff pairs below split on
  // the value one way or the other (the mechanism as a cell, not a claim)
  run cmFieldValueSensitivityWitnessed = {
    init
      .expect(
        verdictOf(shFfCat("wr-none", false), "A", "a", "present") == "ok"
        and verdictOf(shFfCat("wr-none", true), "A", "a", "present") == "defer"
        and verdictOf(shFfCat("wr-unres", false), "A", "a", "present") == "ok"
        and verdictOf(shFfCat("wr-B", false), "A", "a", "present") == "undescribed")
      .then(stutter)
  }

  run catalogueCalibrationNo = {
    init
      .expect(describedOf(shCat("wall-path", "s"), "A", "absent") == Set())
      .then(stutter)
  }

  // ---- select-target ceiling cells ----
  // the row beneath is named by the cell (literal), so a cell never depends
  // on the sampling order of the lane's own writes. It reads the same pure
  // function the property states its ceiling with.
  // the row the select's arm hands on carries :a and :c, not :z. The ceiling
  // refuses :z - the row beneath lacks it - and serves :a.
  run cmTargetRowRefusesRowLackingName = {
    init
      .expect(targetRowVerdict("row", "z", Set("a", "c")) == "refuse"
              and targetRowVerdict("row", "a", Set("a", "c")) == "serve")
      .then(stutter)
  }
  // an outer group's key list does not rescue a target. :sum_pay on
  // the row the inner group hands on ({emp count_emp}) is REFUSED; the same
  // name on a row carrying it is SERVED. The node's row alone decides.
  run cmTargetRowRefusesPassThroughName = {
    init
      .expect(targetRowVerdict("row", "sum_pay", Set("emp", "count_emp")) == "refuse"
              and targetRowVerdict("row", "sum_pay", Set("emp", "sum_pay", "count_emp")) == "serve")
      .then(stutter)
  }
  // an OPEN row beneath defers: the select never refuses a target on a row
  // nobody can decide (the false-refusal rule), whether or not the row is thought to hold it
  run cmTargetOpenRowDefers = {
    init
      .expect(targetRowVerdict("open", "z", Set("a")) == "defer"
              and targetRowVerdict("open", "z", Set()) == "defer")
      .then(stutter)
  }
  // no determinable scope beneath: the engine is the oracle, every
  // catalogue state defers the target
  run cmTargetNoScopeDefers = {
    init
      .expect(
        Shapes.forall(s =>
          targetRowVerdict("none", "z", describedOf(shCat(s, "s"), csubj, cmode)) == "defer"))
      .then(stutter)
  }
  // the projection the node publishes never decides its targets: for every
  // projection row and every shape, a target the projection admits is a
  // target the walk serves without it (limb (c) as a cell, in the walk's
  // vocabulary). Its red form is the mutant
  // (`targetThroughProjection` serving on any non-empty published row).
  run cmTargetPublishedRowNeverRescues = {
    init
      .expect(
        ProjRows.forall(p =>
          Shapes.forall(s =>
            Cols.forall(n =>
              targetThroughProjection(p, n, describedOf(shCat(s, "s"), csubj, cmode),
                                      verdictOf(shCat(s, "s"), csubj, n, cmode)) == "serve"
              implies verdictOf(shCat(s, "s"), csubj, n, cmode) == "ok"))))
      .then(stutter)
  }
  // the boundary itself, on literal rows: a projection admits only what it
  // carries AND the walk serves; pass-through inherits the walk's answer
  run cmTargetBoundaryIsCarriedAndServed = {
    init
      .expect(
        targetThroughProjection("projection", "z", Set("a", "b"), "ok") == "refuse"
        and targetThroughProjection("projection", "a", Set("a", "b"), "ok") == "serve"
        and targetThroughProjection("projection", "a", Set("a", "b"), "err") == "refuse"
        and targetThroughProjection("pass-through", "a", Set(), "ok") == "serve"
        and targetThroughProjection("pass-through", "a", Set(), "err") == "refuse")
      .then(stutter)
  }
  // the row-mode verdict is monotone in the row only: a row carrying every
  // name serves all of them, an empty row refuses them all, and no name is
  // served by being absent
  run cmTargetCeilingIsTheRowAlone = {
    init
      .expect(
        Cols.forall(n =>
          UnderRows.forall(u =>
            targetRowVerdict(u, n, Cols) == (if (u == "row" or u == "undecidable") "serve" else "defer")
            and targetRowVerdict(u, n, Set()) == (if (u == "row" or u == "undecidable") "refuse" else "defer"))))
      .then(stutter)
  }

  // select-target cells: the rowless lane's authority, per row state. The green
  // form asserts what the contract says; the three MUTANT forms below are
  // the same assertion against the three one-line mutant lanes, and each
  // must REFUSE (a `run` red is the mutant's death certificate).
  run cmRowlessLaneServesNothingOnARow = {
    init
      .expect(
        Lanes.forall(l =>
          Cols.forall(n =>
            (rowlessLaneVerdict(l, "row", n, cdesc) == "serve") == cdesc.contains(n))))
      .then(stutter)
  }
  run cmRowlessLaneDefersWithoutARow = {
    init
      .expect(
        Lanes.forall(l =>
          UnderRows.forall(u =>
            (u == "row") or (u == "undecidable")
            or Cols.forall(n =>
                 rowlessLaneVerdict(l, u, n, cdesc) == "defer"))))
      .then(stutter)
  }
  // M3: a lane that defers everywhere. It agrees with the contract on
  // unreadable rows and dies on the readable one - vacuity cannot survive
  // a limb that demands a serve.  // LIVE MUTANT, DELIBERATE: red by construction and kept red. It is the
  // catalogue leg's red-first instrument (the proof the leg can fail), so
  // the spec gate does not select it. See the model header, Verification.
  run cmRowlessMutantVacuity = {
    init
      .expect(
        Lanes.forall(l =>
          Cols.forall(n =>
            rowlessLaneVerdict(l, "row", n, cdesc) == "defer")))
      .then(stutter)
  }
  // the unproven lane: `:noproof` is a lane ANSWER, so
  // it defers where no row decides and is inert where one does - the same
  // two facts the other answers obey. A lane-derived refusal on
  // the unproven answer, or a
  // lane-derived serve, is the shape a mutant takes.
  run cmUnprovenLaneDefersAndIsInert = {
    init
      .expect(
        Cols.forall(n =>
          rowlessLaneVerdict("unproven", "none", n, cdesc) == "defer"
          and rowlessLaneVerdict("unproven", "open", n, cdesc) == "defer"
          and rowlessLaneVerdict("unproven", "row", n, cdesc)
              == (if (cdesc.contains(n)) "serve" else "refuse")))
      .then(stutter)
  }

  // agree-copy shares one column block (LAB) across its own and alien
  // entries, so `usable` rejects both own entries and the arm is not
  // described. Measured by verify (temporal + --invariant) for the values
  // below, which are the ones that hold.
  run t1 = { init.expect(not(describedAbsent(shCat("agree-copy","y"),"A"))).then(stutter) }  run t2 = { init.expect(describedOf(shCat("agree-copy","y"),"A","absent") == Set()).then(stutter) }
  run t3 = { init.expect(verdictOf(shCat("agree-copy","y"),"A","a","absent") == "undescribed").then(stutter) }
  run t4 = { init.expect(verdictOf(shCat("agree-copy","s"),"A","a","absent") == "undescribed").then(stutter) }
  // ---- the same-path pair ----
  // The pair's row is the union of the OWNERS' own keys (their per-owner
  // canon facts), and the shared text is own to neither. The named killer
  // mutant is the COLLAPSE (`ownCanon` giving both owners one canon): the
  // second owner's canon becomes the shared text, and every cell below
  // dies on the copy while the model stays green (red-first evidence).
  run cmSamePathOwnersKeepDistinctKeys = {
    init
      .expect(samePathOwnersKeepDistinctKeys
              and sharedTextIsOwnedByNeither)
      .then(stutter)
  }
  // the pair's row carries the owners' keys and NOT the shared text: a
  // target naming the shared text is refused, a target naming an owner's
  // address is served. The
  // per-owner CANONS are the measured tree facts (:canons {1 "/d/v1"
  // 2 "/d/v1"} under two distinct owners) restated as distinct texts.
  run cmSamePathPairRowRefusesTheSharedText = {
    init
      .expect(sharedPathVerdict("C1") == "refuse"
              and sharedPathVerdict("a1") == "serve"
              and sharedPathVerdict("a2") == "serve"
              and sharedPathVerdict("C2") == "serve"
              and ownCanon("A") == "C1" and ownCanon("B") == "C2"
              and not(ownCanon("A") == ownCanon("B")))
      .then(stutter)
  }
  // ---- the undecidable row ----
  // THE LAW: the described-union row decides - carried names serve,
  // unknown names refuse; applies exactly when every arm's record is readable
  // and identity is undecidable; a read-failed arm keeps the open row and
  // defers. The limb states BOTH halves: on the "undecidable" row the verdict
  // is membership (a carried name serves, an unknown one refuses), and on the
  // read-failed "open" row the verdict is the deferral - so the two states
  // cannot be collapsed into one without the limb dying.
  val undecidableRowDecidesByMembership =
    clane != "done"
    or(and {
      Lanes.forall(l =>
        Cols.forall(n =>
          rowlessLaneVerdict(l, "undecidable", n, cdesc)
          == (if (cdesc.contains(n)) "serve" else "refuse"))),
      Lanes.forall(l =>
        Cols.forall(n =>
          rowlessLaneVerdict(l, "open", n, cdesc) == "defer")),
    })
  // The named killer mutant is BLANKET-REFUSAL (`undecidable` refuses every
  // name): the first conjunct dies on every carried
  // name, while the model stays green. The other direction (a mutant that
  // SERVES every name on "undecidable") is killed by the same conjunct on
  // every unknown name. A support run pins the refuse direction.
  run cmUndecidableRowDecidesByMembership = {
    init.expect(undecidableRowDecidesByMembership).then(stutter)
  }

}


