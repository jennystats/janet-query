// Catalogue lane, part B: the SHAPE lane.
//
// Module: catalogueShapes. THE WALK, stated once: the absent-mode admission
// (the catalogue carrying no writer field), the writer VALUE
// domain, the 25 catalogue shapes (spellings x alias/path x union shapes x
// shared-block configurations) and the key-role table.
//
// The walked model (catalogue-record.qnt) and the mutant builders import
// this module: a WALK mutant is a change here, an ORACLE mutant a change to
// catalogue-record.qnt. The split exists so a mutant kill names which side
// moved.

module catalogueShapes {

  type Ent = {eid: str, key: str, cols: Set[str], writer: str}
  val Cols = Set("a", "b", "c", "d", "q", "x", "y", "z")
  val Records = Set("A", "B")
  val Modes = Set("absent", "present")
  val Forms = Set("s", "k", "y")
  // the writer VALUE domain: not every value names a record
  //   wr-none   - the entry carries no writer field at all
  //   wr-A/wr-B - a name resolving to exactly one record (testimony)
  //   wr-two    - a name text resolving to TWO records: no testimony
  //   wr-nil, wr-false, wr-num, wr-tbl - values that are not record names
  //   wr-unres  - name text resolving to NO record
  val WriterVals = Set("wr-none", "wr-A", "wr-B", "wr-two", "wr-nil",
                       "wr-false", "wr-num", "wr-tbl", "wr-unres")

  // ---- spellings (variant expansion): a name text answers to its string,
  // keyword and symbol forms; a record's OWN KEYS are the forms of its path
  // and, when it carries one, its alias ----
  pure def ownKeys(r: str): Set[str] =
    if (r == "A")
      Set("s:pa.parquet", "k:pa.parquet", "y:pa.parquet",
          "s:x", "k:x", "y:x")
    else
      Set("s:pb.parquet", "k:pb.parquet", "y:pb.parquet")

  // the key a ROLE is written under, in one form. Roles: alias (A), path (A),
  // path (B), and an alien text no record answers to
  pure def keyOf(role: str, form: str): str =
    if (role == "alias")
      (if (form == "s") "s:x" else (if (form == "k") "k:x" else "y:x"))
    else if (role == "apath")
      (if (form == "s") "s:pa.parquet"
       else (if (form == "k") "k:pa.parquet" else "y:pa.parquet"))
    else if (role == "bpath")
      (if (form == "s") "s:pb.parquet"
       else (if (form == "k") "k:pb.parquet" else "y:pb.parquet"))
    else
      (if (form == "s") "s:q" else (if (form == "k") "k:q" else "y:q"))

  val Shapes = Set("empty", "own-agree", "own-disagree", "s1-shape",
                   "own-dup", "own-overlap", "alien-copy", "alien-other",
                   "lone-block", "wall-path", "wall-alias", "cross-copy",
                   "agree-copy", "b-own",
                   // the two-key disagreement - A described at
                   // BOTH its keys, the second a STRICT SUBSET of the first
                   // (`{pa: [a b], "p.parquet": [b]}`). The union over A's
                   // own keys admits `:a`; the second key alone does not.
                   "own-subset",
                   // writer-VALUE field shapes
                   "ff-own", "ff-peer-none", "ff-peer-nil", "ff-peer-false",
                   "ff-two-own", "ff-none-elsewhere", "ff-nil-elsewhere",
                   "ff-two-elsewhere", "ff-blocked", "ff-mixed", "ff-unres")
  // the fourteen absent-mode shapes (the byte-faithfulness floor; every
  // one carries testimony or no field at all, so they are the
  // FIXTURES for a catalogue carrying no writer field, not a second writer
  // vocabulary)
  val BaseShapes = Set("empty", "own-agree", "own-disagree", "s1-shape",
                       "own-dup", "own-overlap", "alien-copy", "alien-other",
                       "lone-block", "wall-path", "wall-alias", "cross-copy",
                       "agree-copy", "b-own",
                       // the record-name writer, so the same domain -
                       // it is not one of the base fixtures, it shares their
                       // vocabulary. cmShapePartition reads this set.
                       "own-subset")
  // the value domain (testimony or no field); the writer values
  // are the field shapes' business
  // The base fixtures write the RECORD NAME into `writer` (that field holds
  // names, never value ids - `ffCat` maps value -> name through `wrNames`),
  // so the domain here is the set of names the base catalogue uses.
  val V30Vals = Set("A", "B", "")

  // the column lists the shapes use
  pure def LAB: Set[str] = Set("a", "b")
  pure def LC: Set[str] = Set("c")
  pure def LCD: Set[str] = Set("c", "d")
  pure def LXY: Set[str] = Set("x", "y")
  pure def LYZ: Set[str] = Set("y", "z")
  pure def LABQ: Set[str] = Set("a", "b", "q")
  pure def LBC: Set[str] = Set("b", "c")
  pure def LD: Set[str] = Set("d")
  pure def LSEQB: Set[str] = Set("b")

  // ---- the shapes: variant expansion x alias/path x union shape x
  // shared-block configuration; `cwr` is the writer ALPHABET (record
  // names for the base shapes, value ids for the field shapes) ----

  // an entry: the key it sits under, its column set, its WRITER (ground
  // truth in both modes; only the writer lane reads it)
  pure def ent(role: str, form: str, cols: Set[str], writer: str): Ent =
    { eid: role, key: keyOf(role, form), cols: cols, writer: writer }

  // the record(s) a writer value names
  pure def wNames(w: str): Set[str] =
    if (w == "wr-A") Set("A")
    else if (w == "wr-B") Set("B")
    else if (w == "wr-two") Set("A", "B")
    else Set()

  // the catalogue of one shape, in one key form. `cwr` is the writer
  // ALPHABET: record names ("names") for the base shapes, value ids
  // ("values") for the field shapes. Both lanes keep the absent-mode
  // functions reader-blind to it.
  pure def shCat(shape: str, form: str): Set[Ent] =
    if (shape == "own-agree")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LAB, "A"))
    else if (shape == "own-disagree")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LCD, "A"))
    else if (shape == "s1-shape")
      Set(ent("alias", form, LXY, "A"), ent("apath", form, LYZ, "A"))
    else if (shape == "own-dup")
      Set(ent("alias", form, LABQ, "A"))
    else if (shape == "own-overlap")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LBC, "A"))
    else if (shape == "alien-copy")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LC, "A"),
          ent("alien", form, LAB, "B"))
    else if (shape == "alien-other")
      Set(ent("alias", form, LAB, "A"), ent("alien", form, LD, "B"))
    else if (shape == "lone-block")
      Set(ent("alien", form, LAB, "B"))
    else if (shape == "wall-path")
      Set(ent("apath", form, LYZ, "B"))
    else if (shape == "wall-alias")
      Set(ent("alias", form, LYZ, "B"))
    else if (shape == "cross-copy")
      Set(ent("alias", form, LAB, "A"), ent("bpath", form, LAB, "B"))
    else if (shape == "agree-copy")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LAB, "A"),
          ent("alien", form, LAB, "B"))
    else if (shape == "b-own")
      Set(ent("bpath", form, LAB, "B"))
    else if (shape == "own-subset")
      Set(ent("alias", form, LAB, "A"), ent("apath", form, LSEQB, "A"))
    else if (shape == "ff-own")
      Set(ent("alias", form, LAB, "wr-none"))
    else if (shape == "ff-peer-none")
      Set(ent("alias", form, LAB, "wr-A"))
    else if (shape == "ff-peer-nil")
      Set(ent("alias", form, LAB, "wr-nil"))
    else if (shape == "ff-peer-false")
      Set(ent("alias", form, LAB, "wr-false"))
    else if (shape == "ff-two-own")
      Set(ent("alias", form, LAB, "wr-two"))
    else if (shape == "ff-none-elsewhere")
      Set(ent("alias", form, LAB, "wr-none"), ent("alien", form, LAB, "wr-nil"))
    else if (shape == "ff-nil-elsewhere")
      Set(ent("alias", form, LAB, "wr-nil"), ent("alien", form, LAB, "wr-none"))
    else if (shape == "ff-two-elsewhere")
      Set(ent("alias", form, LAB, "wr-two"), ent("alien", form, LAB, "wr-two"))
    else if (shape == "ff-blocked")
      Set(ent("alias", form, LAB, "wr-none"), ent("alien", form, LAB, "wr-none"))
    else if (shape == "ff-mixed")
      Set(ent("alias", form, LAB, "wr-A"), ent("apath", form, LAB, "wr-num"))
    else if (shape == "ff-unres")
      Set(ent("alias", form, LAB, ""))
    else
      Set()


  // the ffCat cells' constructor: an arm entry under the alias key whose
  // FIELD VALUE is `wv`; the entry's writer names the record the value names
  // (empty for none). The stranger carries the same value (and so the same
  // writer) and the same list at an alien key - item 2's block evidence.
  //
  // KNOWN FIXTURE DEFECT: `shWrNames` writes the RECORD NAME into the
  // entry's writer field, while the fieldless test in catalogue-record.qnt
  // reads VALUE IDS. An `ff-*` entry therefore reads as fieldless to the
  // test and as a record's own claim to `ownWriterUnion`, which is why the
  // present-mode `ps2Neutrality` and `absorptionNever` runs are red on the
  // `ff-*` shapes. The defect is in this fixture, not in the admissibility
  // rule (certified by `pbS2` in catalogue-partb.qnt).
  pure def shWrNames(wv: str): str =
    if (wv == "wr-A") "A" else if (wv == "wr-B") "B" else ""
  pure def shFfEnt(role: str, wv: str): Ent =
    { eid: role, key: keyOf(role, "s"), cols: LAB, writer: shWrNames(wv) }
  pure def shFfCat(wv: str, stranger: bool): Set[Ent] =
    if (stranger)
      Set(shFfEnt("alias", wv), shFfEnt("alien", wv))
    else
      Set(shFfEnt("alias", wv))

  // ---- the absent-mode walk (the catalogue carrying no writer field) ----
  pure def absentOwn(cat: Set[Ent], r: str): Set[Ent] =
    cat.filter(e => e.key.in(ownKeys(r)))
  // the shared-block set: the lists ALIEN keys carry (any key that is not
  // one of the record's own - including another record's own key)
  pure def othersLists(cat: Set[Ent], r: str): Set[Set[str]] =
    cat.filter(e => not(e.key.in(ownKeys(r)))).map(e => e.cols)
  pure def usable(e: Ent, cat: Set[Ent], r: str): bool =
    not(e.cols.in(othersLists(cat, r)))
  pure def absentUsable(cat: Set[Ent], r: str): Set[Ent] =
    absentOwn(cat, r).filter(e => usable(e, cat, r))
  // DESCRIBED (ks non-nil at the tree): a usable own entry exists
  pure def describedAbsent(cat: Set[Ent], r: str): bool =
    absentUsable(cat, r).exists(e => not(e.cols == Set()))
  // the union walk: every usable own entry contributes, de-duplicated
  pure def unionAbsent(cat: Set[Ent], r: str): Set[str] =
    absentUsable(cat, r).map(e => e.cols).flatten()
}
