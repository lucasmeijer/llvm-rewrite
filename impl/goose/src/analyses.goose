// Analysis ids and preserved-analysis sets (llvm/include/llvm/IR/PassManager.h PreservedAnalyses), shared by
// the pass manager and every pass. Bit i of a preserved set = analysis A_i is preserved. PA_CFG is LLVM's
// preserveSet<CFGAnalyses>: every analysis that only depends on the CFG (DominatorTree, PostDominatorTree,
// LoopInfo, CycleInfo). A pass that changes the CFG but updates some trees returns those bits explicitly
// (ADCE: dom | postdom, not loops).
let A_DOMTREE = 0;
let A_POSTDOMTREE = 1;
let A_DEMANDED_BITS = 2;     // computed per query; listed so require<>/invalidate<> parse
let A_LOOPS = 3;
let A_CYCLES = 4;
let A_MEMORYSSA = 5;
let A_AA = 6;              // AAManager: stateless; invalidating it (or the DT) invalidates MemorySSA
let A_LRT = 8;               // LastRunTrackingAnalysis (InstCombine skips a rerun with no change in between)
let A_SCEV = 7;              // ScalarEvolution: invalidated unless preserved explicitly, or when domtree/loops go
let A_LVI = 12;              // LazyValueAnalysis: invalidated unless preserved explicitly
let A_BPI = 13;              // BranchProbabilityAnalysis
let A_BFI = 14;              // BlockFrequencyAnalysis
let A_VERIFY = 20;
let A_TARGET_IR = 21;        // TargetIRAnalysis: require<target-ir> creates the function's subtarget
let A_ORE = 22;              // OptimizationRemarkEmitterAnalysis: no state without -pass-remarks-with-hotness           // VerifierAnalysis: require<verify> is accepted; no verifier yet (the harness verifies our output)
let PA_ALL: u32 = 0xFFFFFFFF;
let PA_NONE: u32 = 0;
let PA_CFG: u32 = 0x1B;      // domtree | postdomtree | loops | cycles
