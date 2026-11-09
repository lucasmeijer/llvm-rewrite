# L1.vectorize bundled three passes of very different size into one unit; split it

- **Date / implementation / unit:** 2026-11-24 / jai / L1.vectorize (VectorCombine + SLPVectorizer)
- **What happened:** L1.vectorize's exit selector covered LoopVectorize (468 files), SLPVectorizer (650) and
  VectorCombine (65), 2366 checks. The assignment was VectorCombine + SLP with LoopVectorize left for later, so the
  unit could never report COMPLETE for this work, and `status` gave no signal of progress per pass. The pass sizes
  differ by an order of magnitude: VectorCombine.cpp is 6.6k lines and was ported and passing in one sitting;
  SLPVectorizer.cpp is 33k lines (the largest file in the tree by far), LoopVectorize + VPlan more still.
- **Time or effort lost:** little: the split took a few minutes. Without it, "is VectorCombine done?" would have needed a
  hand-written glob each time.
- **What would have helped:** pass units sized by the LLVM source they port; anything above ~10k lines of source split
  up front (SLP itself could be split by test directory or by feature, e.g. stores/reductions/revec).
- **What you did instead:** split docs/roadmap.md into L1.vectorize.vector-combine, L1.vectorize.slp and
  L1.vectorize.loop (each `<Pass>/*::roundtrip` + `<Pass>/*::opt`, the same tests as before) and kept L1.vectorize
  with its original exit selector, now depending on the three. Nothing was loosened: the union of the three new
  selectors equals the old one.
