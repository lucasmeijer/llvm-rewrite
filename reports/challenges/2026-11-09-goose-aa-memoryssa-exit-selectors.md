# Analysis unit exits include tests that need unrelated passes, flags and targets

- **Date / implementation / unit:** 2026-11-09 / goose / L1.analysis.aa, L1.analysis.memoryssa
- **What happened:** both units were ported whole (aggregation, BasicAA, TBAA, ScopedNoAliasAA, GlobalsAA,
  CaptureTracking, MemorySSA with walker and printers) and agree with LLVM on every imported Transforms test
  in a sweep, but neither reports COMPLETE. L1.analysis.aa's exit contains three BasicAA tests whose RUN lines
  are `-mtriple=… -passes=inferattrs,aa-eval` (they test the InferFunctionAttrs pass and BuildLibCalls'
  1100-line attribute table, one of them on a Darwin triple, which needs a Darwin TargetLibraryInfo), and two
  that need 128-bit/66-bit APInt arithmetic in GEP decomposition (and known bits wider than 64 bits).
  L1.analysis.memoryssa's exit contains 7 tests that run `loop-mssa(licm|loop-rotate|simple-loop-unswitch)`,
  i.e. the loop pass manager, three loop passes and the MemorySSAUpdater.
- **Time or effort lost:** little time lost, but the unit status is misleading: "not complete" for analyses
  that are done, and the remaining work is units of their own (inferattrs, loop passes, MemorySSAUpdater).
- **What would have helped:** exit selectors for analysis units that exclude imported tests whose pipeline
  contains transforms other than `require<>`/`invalidate<>`/printers (the importer knows the pipeline), or a
  roadmap convention that such tests belong to the pass unit (here: an `L1.inferattrs` unit and the LICM /
  loop-rotate units) rather than to the analysis.
- **What you did instead:** ported everything the analysis itself does, made the other cases fail loudly, and
  verified the analyses with my own differential sweeps over the 5007 `tests/imported/llvm/Transforms` files
  (aa-eval with the default pipeline and `-evaluate-aa-metadata`, `print<memoryssa>`,
  `print<memoryssa-walker>`, globals-aa). Such a sweep found more than the unit tests did (e.g. the
  `UnknownFunctionsWithLocalLinkage` move-constructor quirk in GlobalsAA, numbered struct types in printers);
  a harness command for "compare printer X over directory Y against LLVM" would make this standard.
