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
let A_VERIFY = 20;           // VerifierAnalysis: require<verify> is accepted; no verifier yet (the harness verifies our output)
let PA_ALL: u32 = 0xFFFFFFFF;
let PA_NONE: u32 = 0;
let PA_CFG: u32 = 0x1B;      // domtree | postdomtree | loops | cycles
