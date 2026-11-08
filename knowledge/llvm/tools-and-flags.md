# Tools and flags (LLVM 23.1.5)

- **`llc -stop-before=x86-isel` writes MIR**, not plain IR: a YAML document whose first block (`--- |`, indented by two
  spaces, ending at `...`) is the IR module, followed by per-function MIR stubs. The harness extracts the IR block
  (`harness/lrh/checks.py:extract_ir`). It works at both -O0 and -O2, because x86 uses `x86-isel` (SelectionDAG/FastISel)
  at -O0 too, not GlobalISel. Verified by running it on clang -O0 and -O2 IR.
- **`-opt-bisect-limit=N`** prints one stderr line per bisectable pass:
  `BISECT: running pass (N) <pass> on <function|[module]>` or `BISECT: NOT running pass …`. With `-O2` on a small
  module there are about 190 bisectable passes. Required passes (verifier, analyses, printers, `require<>`,
  `invalidate<>`, pass managers/adaptors) aren't counted. The `<pass>` is the textual pipeline name (`dce`), the IR
  is the function's name. Passes on `optnone` functions are still counted and printed: every shouldRun callback
  runs (`ShouldRun &= C(...)`), OptNone's just vetoes them. Declarations aren't visited at all.
- **Pipeline wrapping** (`PassBuilder::parsePassPipeline`): if the *first* element isn't a module pass, the whole
  list is wrapped in `function(...)` (or `cgscc(...)`, `function(loop(...))`). Otherwise each function pass appearing
  directly in the module list gets its own `ModuleToFunctionPassAdaptor`, so `module-pass,dce,adce` runs dce over all
  functions, then adce over all functions. `parsePipelineText` splits on `,()` only: `<...>` parameters are part of
  the name and can't contain those characters.
- **`opt -O2 -print-pipeline-passes`** prints the full textual pipeline, with every pass parameter spelled out
  (e.g. `simplifycfg<bonus-inst-threshold=1;…>`). That's the ground truth for pipeline order.
- **ModuleID**: `opt -S file.ll` prints `; ModuleID = 'file.ll'`, using the path exactly as given. `llvm-dis` reading
  stdin prints `; ModuleID = '<stdin>'`. The harness always passes repo-relative paths with cwd = repo root, and
  canonicalizes through stdin.
- **The release tarball** uses a zstd window larger than the default decoder limit. Decompress with
  `zstd -d --long=31`. It's 12 GB unpacked; the workspace image keeps only the tools in
  `.agents-in-the-cloud/image/install-toolchains.sh` (1.5 GB).
- **There's no FileCheck** in the release tarball. We don't use it: imported tests' CHECK lines are ignored, and opt's
  real output is the oracle.
- **llc runs its IR passes under the legacy pass manager.** `-debug-pass-manager` prints nothing. Use
  `llc -debug-pass=Structure -stop-before=x86-isel` to list them. At -O2 the list includes pre-isel-intrinsic-lowering,
  expand-ir-insts, atomic-expand, x86-lower-amx-*, loop-reduce (LSR) and codegenprepare, among others.
- **Unknown x86 CPUs/features warn on stderr when a subtarget is created**, not when the module is parsed:
  `'+mpx' is not a recognized feature for this target (ignoring feature)` (MCSubtargetInfo.cpp ApplyFeatureFlag; the
  feature is lower-cased and gets a `+` if it has no sign). opt creates the TargetMachine's subtarget from
  `-mcpu`/`-mattr` once (one warning per unknown feature). A function's subtarget
  (X86TargetMachine::getSubtargetImpl, keyed by prefer-vector-width, min-legal-vector-width, target-cpu, tune-cpu,
  use-soft-float and target-features) is created the first time anything asks for its TTI, and
  AssumptionAnalysis does: every pass or analysis that uses an AssumptionCache (BasicAA, SCEV, DemandedBits,
  MemorySSA, SROA, mem2reg, SCCP, instsimplify, loop-simplify, the loop pass adaptor even for a function without
  loops) triggers it; domtree/loops/cycles printers, dce, adce, lcssa, break-crit-edges don't. Each new key prints
  each unknown feature **twice** (X86GenSubtargetInfo's constructor and initializeSubtargetDependencies both run
  InitMCProcessorInfo); a key seen before prints nothing. print<scalar-evolution> prints its `Printing analysis`
  header first, the other printers after. An unknown `target-cpu` warns several times and then aborts with
  `LLVM ERROR: 64-bit code requested on a subtarget that doesn't support it!`. Verified with opt on a module with
  `"target-features"="+mpx,+foo,-bar"` (LoopVectorize/X86/int128_no_gather.ll has `+mpx`).
