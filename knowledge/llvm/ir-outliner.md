# IRSimilarityIdentifier and IROutliner

`print-ir-similarity` (IRSimilarityAnalysisPrinterPass, to stderr) and `iroutliner` (IROutlinerPass). Sources:
lib/Analysis/IRSimilarityIdentifier.cpp, lib/Support/SuffixTree.cpp, lib/Transforms/IPO/IROutliner.cpp. Everything
here was checked against `opt` 23.1.5 on the IROutliner / IRSimilarityIdentifier tests and a whole-corpus sweep of
both passes (see impl/jai/NOTES.md for the numbers).

## Orders that decide the output

- The output order is the suffix tree's: `SuffixTree` children are a `DenseMap<unsigned, SuffixTreeNode *>` keyed by
  the instruction numbers, the repeated substrings come from a DFS stack over them, the start indices of a substring
  are its leaf children in that map's order, then `stable_sort` by length. Groups of one substring come out in
  `DenseMap<unsigned, SimilarityGroup>` (group number) bucket order. So reproducing the output means reproducing the
  bucket layout of LLVM 23's DenseMap: `DenseMapInfo<unsigned>::getHashValue = Val * 37`, linear probing (not the
  quadratic probing of older LLVMs), a "used" bitmap instead of tombstones, deletion by Knuth's Algorithm R (entries
  shift back), grow at 3/4 load to `max(64, NextPowerOf2(2 * NumBuckets - 1))`, `clear()` shrinks when
  `NumEntries * 4 < NumBuckets && NumBuckets > 64`, `remove_if` (and so `set_intersect`) rehashes, a copy keeps the
  layout, `DenseSet{x}` starts with 4 buckets (llvm/include/llvm/ADT/DenseMap.h).
- The GVN mapping sets of compareStructure are `DenseSet<unsigned>`; createCanonicalRelationFrom picks "the first"
  value of a set with several candidates (commutative operands), so their layout matters too.
- The candidate's own block numbering walks a `DenseSet<BasicBlock *>` (address order). It only permutes the
  canonical numbers among the candidate's blocks, and those are only compared for equality, so it does not show.
- CheckLargerCands walks `DenseSet<IRSimilarityCandidate *>` (address order) and keeps the first larger candidate per
  group; when two group numbers share a home bucket the first group of the intersection depends on that order too.
  On the corpus every possible choice gives the same canonical numbering (checked by computing all of them).
- IROutliner: the exits of a region are a `SmallPtrSet<BasicBlock *, 1>`: with two or more exits the PHINode outputs
  are added in pointer order (the order of the output arguments). No corpus file has two exits with PHINode outputs.

## Behaviour that is easy to get wrong

- A GEP without indices (`getelementptr i8, ptr %p`) is close to nothing: isClose does
  `all_of(drop_begin(zip(GEP->indices(), Other->indices())), ...)`, and `drop_begin` of the empty zip steps past its
  end, so the comparison reads the memory behind the operand lists (the GEPs' `Type *`, then their ilist links, which
  differ). Every such GEP gets its own instruction number (Analysis/BasicAA/gep-nuw-alias.ll,
  SLPVectorizer/X86/vec3-reorder-reshuffle.ll).
- A call of an unknown `llvm.*` function is an `IntrinsicInst` (isIntrinsic is the name prefix) but InstVisitor
  dispatches on the intrinsic ID (`not_intrinsic`), so it is classified by visitCallInst (legal); its callee name for
  matching is `Intrinsic::getName(not_intrinsic)` = "not_intrinsic", so it never matches a plain call
  (Transforms/GVN/intrinsics_in_cg.ll). It is still "an intrinsic" for the commutative-operand check.
- The callee name of an overloaded intrinsic is `Intrinsic::getName(ID, FT->params(), M, FT)`: mangled with every
  parameter type, not just the overloaded ones. Only equality of these names matters.
- populateMapper pushes `InstrListForModule.back()` onto the IRInstructionDataList after every function; when the
  function ended on an illegal instruction that row is already the list's last element and simple_ilist links it to
  itself (prev = next = itself until the next push_back repairs `next`). The outliner later inserts before and erases
  ranges around such rows, so the list must be emulated with simple_ilist's exact pointer updates.
- IROutliner's `InstructionAllowed` declares `bool IntrinsicInst(IntrinsicInst &)`, which is not a visit method:
  intrinsics go through `visitCallInst` like any call. `freeze` is illegal for the outliner (legal for similarity).
- createCanonicalRelationFrom(SourceCand, ToSourceMapping, FromSourceMapping) looks up the *target* candidate's GVN
  in the source candidate's canonical numbering (`SourceCand.getCanonicalNum(ResultGVN)`). Ported as is: the
  numberings of structurally similar candidates line up, so this works out.
- The overall function copies every function attribute of the first extracted function
  (`shouldCopyAttributeWhenOutliningFrom` is true on X86), then `mergeAttributesForOutlining` (= mergeFnAttrs, the
  inliner's rules) with each further one: `"less-precise-fpmad"="true"` and `"no-signed-zeros-fp-math"="true"` become
  `"false"` when one region's function lacks them; `noimplicitfloat`, `"no-jump-tables"`, ... are OR-ed.
- moveFunctionData drops debug records and every non-call `!dbg`; calls get `DILocation(0, 0, SP)` only when the
  overall function has a subprogram (otherwise they keep theirs). Every `llvm.loop` gets a new distinct node
  (updateLoopMetadataDebugLocations always rebuilds), with locations moved into the new subprogram if there is one.
- The new subprogram: `DIBuilder::createFunction(File, name, mangled name, File, 0, !{} subroutine type, 0,
  FlagArtificial, SPFlagDefinition | SPFlagOptimized)`: scope and file are the file of the first region's
  subprogram, unit its CU.
