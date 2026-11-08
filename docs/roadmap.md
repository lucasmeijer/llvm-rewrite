# Roadmap

Units of work, shared by every implementation. A unit is **complete for an implementation** when

```
./harness/run check --impl <lang> --unit <ID>
```

reports `COMPLETE`: every test its `exit` selector matches passes, every `exit-file` exists in `impl/<lang>/`, and the
ratchet holds. `./harness/run status` shows the unit × implementation table.

Format (parsed by `harness/lrh/roadmap.py`; keep it exact):

- A unit is a `###` heading whose first word is its ID (`L<layer>.<name>`), then ` — ` and a title.
- `- deps:` units that should be complete first (advice for whoever picks work, not enforced).
- `- exit:` comma-separated test-ID globs (`<path glob>::<check>`; `*` also matches `/`).
- `- exit-file:` files that must exist in `impl/<lang>/`.

Rules for changing this file:

- Add a unit when you find work that deserves its own exit criterion. Split a unit that turned out too large (and
  write a challenge report saying so). Do not loosen an exit selector to make a unit pass.
- A unit whose selector matches no tests shows `no tests` in `status`. Its first step is writing those tests.
- Imported LLVM tests are per pass directory, so `tests/imported/llvm/Transforms/<Pass>/*::opt` is the natural exit for
  porting `<Pass>`, together with `…/<Pass>/*::roundtrip` for the same files. Pass units depend on `L0.print-clang`
  and round-trip only their own directory's inputs, so pass work doesn't wait for all of `L0.print-imported`.
  Import more directories with `./harness/run import-llvm Transforms/<Pass>`.

## Order of work

The middle end comes first: after the IR core (L0), work goes into the optimization passes one at a time (L1), then
interprocedural optimization and the full `opt -O2` pipeline (L2). Everything there is judged by exact IR against
`opt`, so it needs no backend. Code generation (L3, L4) and backend optimization (L5) come later. Don't start an L3+
unit until the human running the agents says so.

Compile-time performance (`./harness/run perf`, see `docs/testing.md`) is reported, not gated: no unit requires a
speed. Look at it after porting a pass, and write down bad scaling in `NOTES.md`.

## Layer 0: IR core (parse, print, verify)

### L0.design — Write the implementation's data-oriented design doc
- deps: none
- exit-file: DESIGN.md

### L0.print-basic — Parse and print hand-written IR exactly like `opt -S`
- deps: L0.design
- exit: tests/roundtrip/*::roundtrip

### L0.print-clang — Round-trip every clang-generated test file
- deps: L0.print-basic
- exit: tests/e2e/*::roundtrip, tests/function/*::roundtrip

### L0.print-imported — Round-trip the inputs of LLVM's own regression tests
- deps: L0.print-clang
- exit: tests/imported/*::roundtrip

## Layer 1: analyses and scalar/loop/vector passes (exact IR)

One pass (or a small family) per unit, checked with `opt -passes=<pass> -S` on LLVM's own tests for that pass.
Analyses (dominator tree, loop info, alias analysis, ScalarEvolution, MemorySSA, …) are built as passes need them.
The last two units are llc's IR-level passes (everything before instruction selection): IR in, IR out, matched
exactly, so they belong here and not with the backend.

### L1.harness-analysis — Support analysis-printer tests (`opt -passes='print<domtree>'`, stderr output)
- deps: none
- exit: tests/analysis/*::analysis

### L1.instsimplify — InstSimplify
- deps: L0.print-clang
- exit: tests/imported/llvm/Transforms/InstSimplify/*::roundtrip, tests/imported/llvm/Transforms/InstSimplify/*::opt

### L1.dce — DCE, ADCE, BDCE
- deps: L0.print-clang
- exit: tests/imported/llvm/Transforms/DCE/*::roundtrip, tests/imported/llvm/Transforms/ADCE/*::roundtrip, tests/imported/llvm/Transforms/BDCE/*::roundtrip, tests/imported/llvm/Transforms/DCE/*::opt, tests/imported/llvm/Transforms/ADCE/*::opt, tests/imported/llvm/Transforms/BDCE/*::opt

### L1.mem2reg — mem2reg (PromoteMemToReg)
- deps: L0.print-clang
- exit: tests/imported/llvm/Transforms/Mem2Reg/*::roundtrip, tests/imported/llvm/Transforms/Mem2Reg/*::opt

### L1.sroa — SROA
- deps: L1.mem2reg
- exit: tests/imported/llvm/Transforms/SROA/*::roundtrip, tests/imported/llvm/Transforms/SROA/*::opt

### L1.early-cse — EarlyCSE
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/EarlyCSE/*::roundtrip, tests/imported/llvm/Transforms/EarlyCSE/*::opt

### L1.sccp — SCCP and IPSCCP
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/SCCP/*::roundtrip, tests/imported/llvm/Transforms/SCCP/*::opt

### L1.simplifycfg — SimplifyCFG
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/SimplifyCFG/*::roundtrip, tests/imported/llvm/Transforms/SimplifyCFG/*::opt

### L1.instcombine.arith — InstCombine: add, sub, mul, div, rem
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/InstCombine/add*::roundtrip, tests/imported/llvm/Transforms/InstCombine/sub*::roundtrip, tests/imported/llvm/Transforms/InstCombine/mul*::roundtrip, tests/imported/llvm/Transforms/InstCombine/*div*::roundtrip, tests/imported/llvm/Transforms/InstCombine/*rem*::roundtrip, tests/imported/llvm/Transforms/InstCombine/add*::opt, tests/imported/llvm/Transforms/InstCombine/sub*::opt, tests/imported/llvm/Transforms/InstCombine/mul*::opt, tests/imported/llvm/Transforms/InstCombine/*div*::opt, tests/imported/llvm/Transforms/InstCombine/*rem*::opt

### L1.instcombine.bitwise — InstCombine: and, or, xor, shifts
- deps: L1.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/and*::roundtrip, tests/imported/llvm/Transforms/InstCombine/or*::roundtrip, tests/imported/llvm/Transforms/InstCombine/xor*::roundtrip, tests/imported/llvm/Transforms/InstCombine/sh*::roundtrip, tests/imported/llvm/Transforms/InstCombine/lshr*::roundtrip, tests/imported/llvm/Transforms/InstCombine/ashr*::roundtrip, tests/imported/llvm/Transforms/InstCombine/and*::opt, tests/imported/llvm/Transforms/InstCombine/or*::opt, tests/imported/llvm/Transforms/InstCombine/xor*::opt, tests/imported/llvm/Transforms/InstCombine/sh*::opt, tests/imported/llvm/Transforms/InstCombine/lshr*::opt, tests/imported/llvm/Transforms/InstCombine/ashr*::opt

### L1.instcombine.cmp — InstCombine: icmp, fcmp
- deps: L1.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/icmp*::roundtrip, tests/imported/llvm/Transforms/InstCombine/fcmp*::roundtrip, tests/imported/llvm/Transforms/InstCombine/icmp*::opt, tests/imported/llvm/Transforms/InstCombine/fcmp*::opt

### L1.instcombine.select — InstCombine: select
- deps: L1.instcombine.cmp
- exit: tests/imported/llvm/Transforms/InstCombine/select*::roundtrip, tests/imported/llvm/Transforms/InstCombine/select*::opt

### L1.instcombine.cast — InstCombine: casts
- deps: L1.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/cast*::roundtrip, tests/imported/llvm/Transforms/InstCombine/trunc*::roundtrip, tests/imported/llvm/Transforms/InstCombine/sext*::roundtrip, tests/imported/llvm/Transforms/InstCombine/zext*::roundtrip, tests/imported/llvm/Transforms/InstCombine/cast*::opt, tests/imported/llvm/Transforms/InstCombine/trunc*::opt, tests/imported/llvm/Transforms/InstCombine/sext*::opt, tests/imported/llvm/Transforms/InstCombine/zext*::opt

### L1.instcombine.memory — InstCombine: loads, stores, allocas, GEPs, mem intrinsics
- deps: L1.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/load*::roundtrip, tests/imported/llvm/Transforms/InstCombine/store*::roundtrip, tests/imported/llvm/Transforms/InstCombine/alloca*::roundtrip, tests/imported/llvm/Transforms/InstCombine/gep*::roundtrip, tests/imported/llvm/Transforms/InstCombine/getelementptr*::roundtrip, tests/imported/llvm/Transforms/InstCombine/mem*::roundtrip, tests/imported/llvm/Transforms/InstCombine/load*::opt, tests/imported/llvm/Transforms/InstCombine/store*::opt, tests/imported/llvm/Transforms/InstCombine/alloca*::opt, tests/imported/llvm/Transforms/InstCombine/gep*::opt, tests/imported/llvm/Transforms/InstCombine/getelementptr*::opt, tests/imported/llvm/Transforms/InstCombine/mem*::opt

### L1.instcombine — All of InstCombine
- deps: L1.instcombine.select, L1.instcombine.bitwise, L1.instcombine.cast, L1.instcombine.memory
- exit: tests/imported/llvm/Transforms/InstCombine/*::roundtrip, tests/imported/llvm/Transforms/InstCombine/*::opt

### L1.aggressive-instcombine — AggressiveInstCombine
- deps: L1.instcombine
- exit: tests/imported/llvm/Transforms/AggressiveInstCombine/*::roundtrip, tests/imported/llvm/Transforms/AggressiveInstCombine/*::opt

### L1.reassociate — Reassociate
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/Reassociate/*::roundtrip, tests/imported/llvm/Transforms/Reassociate/*::opt

### L1.cvp — CorrelatedValuePropagation (LazyValueInfo)
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/CorrelatedValuePropagation/*::roundtrip, tests/imported/llvm/Transforms/CorrelatedValuePropagation/*::opt

### L1.jump-threading — JumpThreading
- deps: L1.cvp, L1.simplifycfg
- exit: tests/imported/llvm/Transforms/JumpThreading/*::roundtrip, tests/imported/llvm/Transforms/JumpThreading/*::opt

### L1.constraint-elimination — ConstraintElimination
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/ConstraintElimination/*::roundtrip, tests/imported/llvm/Transforms/ConstraintElimination/*::opt

### L1.gvn — GVN (MemoryDependence, alias analysis)
- deps: L1.early-cse
- exit: tests/imported/llvm/Transforms/GVN/*::roundtrip, tests/imported/llvm/Transforms/GVN/*::opt

### L1.dse — DeadStoreElimination (MemorySSA)
- deps: L1.gvn
- exit: tests/imported/llvm/Transforms/DeadStoreElimination/*::roundtrip, tests/imported/llvm/Transforms/DeadStoreElimination/*::opt

### L1.memcpyopt — MemCpyOpt
- deps: L1.dse
- exit: tests/imported/llvm/Transforms/MemCpyOpt/*::roundtrip, tests/imported/llvm/Transforms/MemCpyOpt/*::opt

### L1.loop-canonical — LoopSimplify, LCSSA, LoopRotate
- deps: L1.simplifycfg
- exit: tests/imported/llvm/Transforms/LoopSimplify/*::roundtrip, tests/imported/llvm/Transforms/LCSSA/*::roundtrip, tests/imported/llvm/Transforms/LoopRotate/*::roundtrip, tests/imported/llvm/Transforms/LoopSimplify/*::opt, tests/imported/llvm/Transforms/LCSSA/*::opt, tests/imported/llvm/Transforms/LoopRotate/*::opt

### L1.licm — LICM
- deps: L1.loop-canonical
- exit: tests/imported/llvm/Transforms/LICM/*::roundtrip, tests/imported/llvm/Transforms/LICM/*::opt

### L1.indvars — IndVarSimplify (ScalarEvolution)
- deps: L1.loop-canonical
- exit: tests/imported/llvm/Transforms/IndVarSimplify/*::roundtrip, tests/imported/llvm/Transforms/IndVarSimplify/*::opt

### L1.loop-misc — LoopDeletion, LoopIdiom, LoopInstSimplify, LoopSimplifyCFG, LoopLoadElim, LoopDistribute
- deps: L1.indvars
- exit: tests/imported/llvm/Transforms/LoopDeletion/*::roundtrip, tests/imported/llvm/Transforms/LoopIdiom/*::roundtrip, tests/imported/llvm/Transforms/LoopInstSimplify/*::roundtrip, tests/imported/llvm/Transforms/LoopSimplifyCFG/*::roundtrip, tests/imported/llvm/Transforms/LoopLoadElim/*::roundtrip, tests/imported/llvm/Transforms/LoopDistribute/*::roundtrip, tests/imported/llvm/Transforms/LoopDeletion/*::opt, tests/imported/llvm/Transforms/LoopIdiom/*::opt, tests/imported/llvm/Transforms/LoopInstSimplify/*::opt, tests/imported/llvm/Transforms/LoopSimplifyCFG/*::opt, tests/imported/llvm/Transforms/LoopLoadElim/*::opt, tests/imported/llvm/Transforms/LoopDistribute/*::opt

### L1.loop-unroll — LoopUnroll
- deps: L1.indvars
- exit: tests/imported/llvm/Transforms/LoopUnroll/*::roundtrip, tests/imported/llvm/Transforms/LoopUnroll/*::opt

### L1.unswitch — SimpleLoopUnswitch
- deps: L1.licm
- exit: tests/imported/llvm/Transforms/SimpleLoopUnswitch/*::roundtrip, tests/imported/llvm/Transforms/SimpleLoopUnswitch/*::opt

### L1.vectorize — LoopVectorize, SLPVectorizer, VectorCombine (x86 cost model)
- deps: L1.loop-unroll, L1.instcombine
- exit: tests/imported/llvm/Transforms/LoopVectorize/*::roundtrip, tests/imported/llvm/Transforms/SLPVectorizer/*::roundtrip, tests/imported/llvm/Transforms/VectorCombine/*::roundtrip, tests/imported/llvm/Transforms/LoopVectorize/*::opt, tests/imported/llvm/Transforms/SLPVectorizer/*::opt, tests/imported/llvm/Transforms/VectorCombine/*::opt

### L1.scalar-misc — The remaining small scalar passes in the O2 pipeline
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/TailCallElim/*::roundtrip, tests/imported/llvm/Transforms/Float2Int/*::roundtrip, tests/imported/llvm/Transforms/DivRemPairs/*::roundtrip, tests/imported/llvm/Transforms/SpeculativeExecution/*::roundtrip, tests/imported/llvm/Transforms/MergedLoadStoreMotion/*::roundtrip, tests/imported/llvm/Transforms/Sink/*::roundtrip, tests/imported/llvm/Transforms/LowerExpectIntrinsic/*::roundtrip, tests/imported/llvm/Transforms/LowerConstantIntrinsics/*::roundtrip, tests/imported/llvm/Transforms/InferAlignment/*::roundtrip, tests/imported/llvm/Transforms/CallSiteSplitting/*::roundtrip, tests/imported/llvm/Transforms/TailCallElim/*::opt, tests/imported/llvm/Transforms/Float2Int/*::opt, tests/imported/llvm/Transforms/DivRemPairs/*::opt, tests/imported/llvm/Transforms/SpeculativeExecution/*::opt, tests/imported/llvm/Transforms/MergedLoadStoreMotion/*::opt, tests/imported/llvm/Transforms/Sink/*::opt, tests/imported/llvm/Transforms/LowerExpectIntrinsic/*::opt, tests/imported/llvm/Transforms/LowerConstantIntrinsics/*::opt, tests/imported/llvm/Transforms/InferAlignment/*::opt, tests/imported/llvm/Transforms/CallSiteSplitting/*::opt

### L1.codegen-ir — llc -O2's IR passes (CodeGenPrepare, LSR, ExpandMemCmp, …) match exactly
- deps: L1.instcombine, L1.indvars
- exit: tests/imported/llvm/Transforms/CodeGenPrepare/*::roundtrip, tests/imported/llvm/Transforms/LoopStrengthReduce/*::roundtrip, tests/imported/llvm/Transforms/ExpandMemCmp/*::roundtrip, tests/imported/llvm/Transforms/AtomicExpand/*::roundtrip, tests/imported/llvm/Transforms/PreISelIntrinsicLowering/*::roundtrip, tests/imported/llvm/Transforms/PartiallyInlineLibCalls/*::roundtrip, tests/imported/llvm/Transforms/CodeGenPrepare/*::opt, tests/imported/llvm/Transforms/LoopStrengthReduce/*::opt, tests/imported/llvm/Transforms/ExpandMemCmp/*::opt, tests/imported/llvm/Transforms/AtomicExpand/*::opt, tests/imported/llvm/Transforms/PreISelIntrinsicLowering/*::opt, tests/imported/llvm/Transforms/PartiallyInlineLibCalls/*::opt, tests/e2e/O2/*::isel-ir, tests/function/O2/*::isel-ir, tests/e2e/pipeline/*::isel-ir, tests/function/pipeline/*::isel-ir

### L1.isel-ir-O0 — llc -O0's IR-level passes (before instruction selection) match exactly
- deps: L0.print-clang
- exit: tests/e2e/O0/*::isel-ir, tests/function/O0/*::isel-ir

## Layer 2: interprocedural and whole-program optimization (exact IR)

### L2.function-attrs — FunctionAttrs, InferFunctionAttrs
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/FunctionAttrs/*::roundtrip, tests/imported/llvm/Transforms/InferFunctionAttrs/*::roundtrip, tests/imported/llvm/Transforms/FunctionAttrs/*::opt, tests/imported/llvm/Transforms/InferFunctionAttrs/*::opt

### L2.inline — The inliner and its cost model
- deps: L2.function-attrs
- exit: tests/imported/llvm/Transforms/Inline/*::roundtrip, tests/imported/llvm/Transforms/Inline/*::opt

### L2.globals — GlobalOpt, GlobalDCE, ConstantMerge, StripDeadPrototypes, EliminateAvailableExternally
- deps: L1.instsimplify
- exit: tests/imported/llvm/Transforms/GlobalOpt/*::roundtrip, tests/imported/llvm/Transforms/GlobalDCE/*::roundtrip, tests/imported/llvm/Transforms/ConstantMerge/*::roundtrip, tests/imported/llvm/Transforms/StripDeadPrototypes/*::roundtrip, tests/imported/llvm/Transforms/EliminateAvailableExternally/*::roundtrip, tests/imported/llvm/Transforms/GlobalOpt/*::opt, tests/imported/llvm/Transforms/GlobalDCE/*::opt, tests/imported/llvm/Transforms/ConstantMerge/*::opt, tests/imported/llvm/Transforms/StripDeadPrototypes/*::opt, tests/imported/llvm/Transforms/EliminateAvailableExternally/*::opt

### L2.ipo-args — ArgumentPromotion, DeadArgElim, Internalize
- deps: L2.function-attrs
- exit: tests/imported/llvm/Transforms/ArgumentPromotion/*::roundtrip, tests/imported/llvm/Transforms/DeadArgElim/*::roundtrip, tests/imported/llvm/Transforms/Internalize/*::roundtrip, tests/imported/llvm/Transforms/ArgumentPromotion/*::opt, tests/imported/llvm/Transforms/DeadArgElim/*::opt, tests/imported/llvm/Transforms/Internalize/*::opt

### L2.phase-ordering — LLVM's whole-pipeline regression tests
- deps: L2.inline, L1.vectorize
- exit: tests/imported/llvm/Transforms/PhaseOrdering/*::roundtrip, tests/imported/llvm/Transforms/PhaseOrdering/*::opt

### L2.pipeline-O2 — `opt -O2` on clang's pre-optimization IR matches exactly
- deps: L2.phase-ordering
- exit: tests/e2e/pipeline/*::opt, tests/function/pipeline/*::opt

### L2.lto — Multi-module programs: our llvm-link, then `-passes='lto<O2>'`, exact IR (needs harness support for multi-file tests first)
- deps: L2.pipeline-O2
- exit: tests/lto/*::opt

### L2.perf-corpus — Correct output on the compile-time performance corpus (real programs, scaling shapes)
- deps: L2.pipeline-O2
- exit: tests/perf/*::roundtrip, tests/perf/*::opt

## Layer 3: -O0 code generation (x86-64 SysV, AT&T assembly)

Tests in this layer use `llc -O0`. `::run` checks compile, link and run. (The IR that llc's own IR-level passes hand
to instruction selection, `::isel-ir`, is matched earlier, in L1.isel-ir-O0.)

### L3.return — main returns a constant or simple expression (no calls)
- deps: L0.print-basic
- exit: tests/e2e/O0/return/*::run

### L3.basic — Locals, arithmetic, branches, loops, direct calls (no libc)
- deps: L3.return
- exit: tests/e2e/O0/arith/add_sub.ll::run, tests/e2e/O0/control/if_else.ll::run, tests/e2e/O0/control/while_loop.ll::run, tests/e2e/O0/calls/simple_call.ll::run, tests/e2e/O0/memory/local_array.ll::run

### L3.libc-calls — Calling libc: puts, then printf (varargs caller side)
- deps: L3.basic
- exit: tests/e2e/O0/libc/hello_puts.ll::run, tests/e2e/O0/libc/printf_int.ll::run

### L3.arith — Integer arithmetic of every width, including i128
- deps: L3.libc-calls
- exit: tests/e2e/O0/arith/*::run

### L3.control — Branches, loops, switches, short-circuit, goto
- deps: L3.libc-calls
- exit: tests/e2e/O0/control/*::run

### L3.calls — Calls: many args, recursion, function pointers, varargs callee
- deps: L3.libc-calls
- exit: tests/e2e/O0/calls/*::run

### L3.memory — Globals, arrays, pointers, heap, VLAs
- deps: L3.libc-calls
- exit: tests/e2e/O0/memory/*::run

### L3.structs — Aggregates, by-value passing and returning, unions, bitfields
- deps: L3.calls, L3.memory
- exit: tests/e2e/O0/structs/*::run

### L3.float — float, double, x86_fp80, conversions, libm
- deps: L3.libc-calls
- exit: tests/e2e/O0/float/*::run

### L3.intrinsics — memcpy/memset/memmove, bit intrinsics, overflow intrinsics, libc helpers
- deps: L3.calls, L3.memory
- exit: tests/e2e/O0/intrinsics/*::run, tests/e2e/O0/libc/*::run

### L3.misc — Vectors, complex, TLS, atomics, indirectbr, setjmp, small programs
- deps: L3.structs, L3.float, L3.intrinsics
- exit: tests/e2e/O0/misc/*::run, tests/e2e/O0/basic/*::run

### L3.abi — Function tests: our code called from (and calling back into) clang-compiled C
- deps: L3.structs, L3.float
- exit: tests/function/O0/*::run

### L3.test-suite — llvm-test-suite programs at -O0
- deps: L3.misc
- exit: tests/e2e/O0/test-suite/*::run

## Layer 4: code generation for optimized IR

Input is clang -O2 IR (phis, selects, vectors, intrinsics everywhere), compiled with `llc -O2`. Only `::run` here: the
backend may lower however it likes. llc -O2's IR passes are matched exactly in L1.codegen-ir.

### L4.core — Optimized IR for the core areas
- deps: L3.misc
- exit: tests/e2e/O2/return/*::run, tests/e2e/O2/arith/*::run, tests/e2e/O2/control/*::run, tests/e2e/O2/calls/*::run, tests/e2e/O2/memory/*::run

### L4.all — All optimized-IR programs and function tests
- deps: L4.core, L3.abi
- exit: tests/e2e/O2/*::run, tests/function/O2/*::run

### L4.pipeline-run — Our opt -O2 + our llc -O2, run end to end
- deps: L2.pipeline-O2, L4.all
- exit: tests/e2e/pipeline/*::run, tests/function/pipeline/*::run

### L4.lto-run — Multi-module programs through our opt and our llc, run end to end
- deps: L2.lto, L4.all
- exit: tests/lto/*::run

## Layer 5: backend optimization (measured, not matched)

### L5.harness-perf — Extend `harness/run perf` to the speed of generated programs (runtime vs `llc -O2`), and a unit per optimization
- deps: L4.all
- exit: tests/perf/runtime/*::perf
