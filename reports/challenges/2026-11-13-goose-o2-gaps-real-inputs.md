# Pass sweeps on tests/perf/compile miss the -O2 inputs; InstructionCost's fixed point is a hidden trap

- **Date / implementation / unit:** 2026-11-13 / goose / L1.o2-gaps (DFAJumpThreading transform, DependenceAnalysis,
  Delinearization, LoopInterchange, LoopCacheAnalysis)
- **What happened:** the port-pass skill suggests sweeping `function(sroa),<pass>` over tests/perf/compile. For
  dfa-jump-threading that pipeline threads nothing in any of the four programs (0 clones), so the sweep says
  "identical" without exercising the transform. The functions LLVM threads at -O2 (sqlite3AffinityType, dfg_lex,
  ia_lex) only see it after the whole CGSCC pipeline. Separately, LLVM 23's InstructionCost stores 4 x the cost
  (CostGranularity) and `/`, `*` and comparisons act on that; nothing in knowledge/ said so, and I found it only
  because LoopCacheAnalysis prints the fraction (`...951.75`). DFAJumpThreading's cost check had been ported with
  plain integers and passed every test and sweep.
- **Time or effort lost:** ~20 min building the bisect-based inputs; the InstructionCost bug would have stayed silent.
- **What would have helped:** a harness helper that dumps "the module just before pass P runs on function F at -O2"
  (opt-bisect-limit at the index of P), and a sweep mode over those snapshots. I used
  `opt -O2 -opt-bisect-limit=-1 | grep <pass>` for the indices, `-pass-remarks=<pass>` for the functions that
  change, and `opt -O2 -opt-bisect-limit=<n-1> -S` per quartile; that found the lexer bug with labels like
  `..._crit_edge:` (lua) that no corpus file had.
- **What you did instead:** the snapshots above (documented in knowledge/llvm/scalar-misc.md) and a knowledge note on
  InstructionCost granularity in knowledge/llvm/dependence-and-interchange.md. Other ports that do arithmetic on
  InstructionCost (goose's tti `tc_*` saturates at 2^62 but is unscaled) should be checked for the same issue.
