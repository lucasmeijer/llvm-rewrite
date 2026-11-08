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
  porting `<Pass>`. Import more directories with `./harness/run import-llvm Transforms/<Pass>`.

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

## Layer 1: -O0 code generation (x86-64 SysV, AT&T assembly)

Tests in this layer use `llc -O0`. `::run` checks compile, link and run; `::isel-ir` checks the IR that llc's own
IR-level passes hand to instruction selection.

### L1.return — main returns a constant or simple expression (no calls)
- deps: L0.print-basic
- exit: tests/e2e/O0/return/*::run

### L1.basic — Locals, arithmetic, branches, loops, direct calls (no libc)
- deps: L1.return
- exit: tests/e2e/O0/arith/add_sub.ll::run, tests/e2e/O0/control/if_else.ll::run, tests/e2e/O0/control/while_loop.ll::run, tests/e2e/O0/calls/simple_call.ll::run, tests/e2e/O0/memory/local_array.ll::run

### L1.libc-calls — Calling libc: puts, then printf (varargs caller side)
- deps: L1.basic
- exit: tests/e2e/O0/libc/hello_puts.ll::run, tests/e2e/O0/libc/printf_int.ll::run

### L1.arith — Integer arithmetic of every width, including i128
- deps: L1.libc-calls
- exit: tests/e2e/O0/arith/*::run

### L1.control — Branches, loops, switches, short-circuit, goto
- deps: L1.libc-calls
- exit: tests/e2e/O0/control/*::run

### L1.calls — Calls: many args, recursion, function pointers, varargs callee
- deps: L1.libc-calls
- exit: tests/e2e/O0/calls/*::run

### L1.memory — Globals, arrays, pointers, heap, VLAs
- deps: L1.libc-calls
- exit: tests/e2e/O0/memory/*::run

### L1.structs — Aggregates, by-value passing and returning, unions, bitfields
- deps: L1.calls, L1.memory
- exit: tests/e2e/O0/structs/*::run

### L1.float — float, double, x86_fp80, conversions, libm
- deps: L1.libc-calls
- exit: tests/e2e/O0/float/*::run

### L1.intrinsics — memcpy/memset/memmove, bit intrinsics, overflow intrinsics, libc helpers
- deps: L1.calls, L1.memory
- exit: tests/e2e/O0/intrinsics/*::run, tests/e2e/O0/libc/*::run

### L1.misc — Vectors, complex, TLS, atomics, indirectbr, setjmp, small programs
- deps: L1.structs, L1.float, L1.intrinsics
- exit: tests/e2e/O0/misc/*::run, tests/e2e/O0/basic/*::run

### L1.abi — Function tests: our code called from (and calling back into) clang-compiled C
- deps: L1.structs, L1.float
- exit: tests/function/O0/*::run

### L1.test-suite — llvm-test-suite programs at -O0
- deps: L1.misc
- exit: tests/e2e/O0/test-suite/*::run

### L1.isel-ir — llc -O0's IR-level passes match exactly
- deps: L0.print-clang
- exit: tests/e2e/O0/*::isel-ir, tests/function/O0/*::isel-ir

## Layer 2: code generation for optimized IR

Input is clang -O2 IR (phis, selects, vectors, intrinsics everywhere), compiled with `llc -O2`. Only `::run` here: the
backend may lower however it likes. llc -O2's IR passes are matched exactly in L3.codegen-ir.

### L2.core — Optimized IR for the core areas
- deps: L1.misc
- exit: tests/e2e/O2/return/*::run, tests/e2e/O2/arith/*::run, tests/e2e/O2/control/*::run, tests/e2e/O2/calls/*::run, tests/e2e/O2/memory/*::run

### L2.all — All optimized-IR programs and function tests
- deps: L2.core, L1.abi
- exit: tests/e2e/O2/*::run, tests/function/O2/*::run

## Layer 3: analyses and scalar/loop passes (exact IR)

Analyses (dominator tree, loop info, alias analysis, ScalarEvolution, MemorySSA, …) are built as passes need them.

### L3.harness-analysis — Support analysis-printer tests (`opt -passes='print<domtree>'`, stderr output)
- deps: none
- exit: tests/analysis/*::analysis

### L3.instsimplify — InstSimplify
- deps: L0.print-imported
- exit: tests/imported/llvm/Transforms/InstSimplify/*::opt

### L3.dce — DCE, ADCE, BDCE
- deps: L0.print-imported
- exit: tests/imported/llvm/Transforms/DCE/*::opt, tests/imported/llvm/Transforms/ADCE/*::opt, tests/imported/llvm/Transforms/BDCE/*::opt

### L3.mem2reg — mem2reg (PromoteMemToReg)
- deps: L0.print-imported
- exit: tests/imported/llvm/Transforms/Mem2Reg/*::opt

### L3.sroa — SROA
- deps: L3.mem2reg
- exit: tests/imported/llvm/Transforms/SROA/*::opt

### L3.early-cse — EarlyCSE
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/EarlyCSE/*::opt

### L3.sccp — SCCP and IPSCCP
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/SCCP/*::opt

### L3.simplifycfg — SimplifyCFG
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/SimplifyCFG/*::opt

### L3.instcombine.arith — InstCombine: add, sub, mul, div, rem
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/InstCombine/add*::opt, tests/imported/llvm/Transforms/InstCombine/sub*::opt, tests/imported/llvm/Transforms/InstCombine/mul*::opt, tests/imported/llvm/Transforms/InstCombine/*div*::opt, tests/imported/llvm/Transforms/InstCombine/*rem*::opt

### L3.instcombine.bitwise — InstCombine: and, or, xor, shifts
- deps: L3.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/and*::opt, tests/imported/llvm/Transforms/InstCombine/or*::opt, tests/imported/llvm/Transforms/InstCombine/xor*::opt, tests/imported/llvm/Transforms/InstCombine/sh*::opt, tests/imported/llvm/Transforms/InstCombine/lshr*::opt, tests/imported/llvm/Transforms/InstCombine/ashr*::opt

### L3.instcombine.cmp — InstCombine: icmp, fcmp
- deps: L3.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/icmp*::opt, tests/imported/llvm/Transforms/InstCombine/fcmp*::opt

### L3.instcombine.select — InstCombine: select
- deps: L3.instcombine.cmp
- exit: tests/imported/llvm/Transforms/InstCombine/select*::opt

### L3.instcombine.cast — InstCombine: casts
- deps: L3.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/cast*::opt, tests/imported/llvm/Transforms/InstCombine/trunc*::opt, tests/imported/llvm/Transforms/InstCombine/sext*::opt, tests/imported/llvm/Transforms/InstCombine/zext*::opt

### L3.instcombine.memory — InstCombine: loads, stores, allocas, GEPs, mem intrinsics
- deps: L3.instcombine.arith
- exit: tests/imported/llvm/Transforms/InstCombine/load*::opt, tests/imported/llvm/Transforms/InstCombine/store*::opt, tests/imported/llvm/Transforms/InstCombine/alloca*::opt, tests/imported/llvm/Transforms/InstCombine/gep*::opt, tests/imported/llvm/Transforms/InstCombine/getelementptr*::opt, tests/imported/llvm/Transforms/InstCombine/mem*::opt

### L3.instcombine — All of InstCombine
- deps: L3.instcombine.select, L3.instcombine.bitwise, L3.instcombine.cast, L3.instcombine.memory
- exit: tests/imported/llvm/Transforms/InstCombine/*::opt

### L3.aggressive-instcombine — AggressiveInstCombine
- deps: L3.instcombine
- exit: tests/imported/llvm/Transforms/AggressiveInstCombine/*::opt

### L3.reassociate — Reassociate
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/Reassociate/*::opt

### L3.cvp — CorrelatedValuePropagation (LazyValueInfo)
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/CorrelatedValuePropagation/*::opt

### L3.jump-threading — JumpThreading
- deps: L3.cvp, L3.simplifycfg
- exit: tests/imported/llvm/Transforms/JumpThreading/*::opt

### L3.constraint-elimination — ConstraintElimination
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/ConstraintElimination/*::opt

### L3.gvn — GVN (MemoryDependence, alias analysis)
- deps: L3.early-cse
- exit: tests/imported/llvm/Transforms/GVN/*::opt

### L3.dse — DeadStoreElimination (MemorySSA)
- deps: L3.gvn
- exit: tests/imported/llvm/Transforms/DeadStoreElimination/*::opt

### L3.memcpyopt — MemCpyOpt
- deps: L3.dse
- exit: tests/imported/llvm/Transforms/MemCpyOpt/*::opt

### L3.loop-canonical — LoopSimplify, LCSSA, LoopRotate
- deps: L3.simplifycfg
- exit: tests/imported/llvm/Transforms/LoopSimplify/*::opt, tests/imported/llvm/Transforms/LCSSA/*::opt, tests/imported/llvm/Transforms/LoopRotate/*::opt

### L3.licm — LICM
- deps: L3.loop-canonical
- exit: tests/imported/llvm/Transforms/LICM/*::opt

### L3.indvars — IndVarSimplify (ScalarEvolution)
- deps: L3.loop-canonical
- exit: tests/imported/llvm/Transforms/IndVarSimplify/*::opt

### L3.loop-misc — LoopDeletion, LoopIdiom, LoopInstSimplify, LoopSimplifyCFG, LoopLoadElim, LoopDistribute
- deps: L3.indvars
- exit: tests/imported/llvm/Transforms/LoopDeletion/*::opt, tests/imported/llvm/Transforms/LoopIdiom/*::opt, tests/imported/llvm/Transforms/LoopInstSimplify/*::opt, tests/imported/llvm/Transforms/LoopSimplifyCFG/*::opt, tests/imported/llvm/Transforms/LoopLoadElim/*::opt, tests/imported/llvm/Transforms/LoopDistribute/*::opt

### L3.loop-unroll — LoopUnroll
- deps: L3.indvars
- exit: tests/imported/llvm/Transforms/LoopUnroll/*::opt

### L3.unswitch — SimpleLoopUnswitch
- deps: L3.licm
- exit: tests/imported/llvm/Transforms/SimpleLoopUnswitch/*::opt

### L3.vectorize — LoopVectorize, SLPVectorizer, VectorCombine (x86 cost model)
- deps: L3.loop-unroll, L3.instcombine
- exit: tests/imported/llvm/Transforms/LoopVectorize/*::opt, tests/imported/llvm/Transforms/SLPVectorizer/*::opt, tests/imported/llvm/Transforms/VectorCombine/*::opt

### L3.scalar-misc — The remaining small scalar passes in the O2 pipeline
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/TailCallElim/*::opt, tests/imported/llvm/Transforms/Float2Int/*::opt, tests/imported/llvm/Transforms/DivRemPairs/*::opt, tests/imported/llvm/Transforms/SpeculativeExecution/*::opt, tests/imported/llvm/Transforms/MergedLoadStoreMotion/*::opt, tests/imported/llvm/Transforms/Sink/*::opt, tests/imported/llvm/Transforms/LowerExpectIntrinsic/*::opt, tests/imported/llvm/Transforms/LowerConstantIntrinsics/*::opt, tests/imported/llvm/Transforms/InferAlignment/*::opt, tests/imported/llvm/Transforms/CallSiteSplitting/*::opt

### L3.codegen-ir — llc -O2's IR passes (CodeGenPrepare, LSR, ExpandMemCmp, …) match exactly
- deps: L3.instcombine, L3.indvars
- exit: tests/imported/llvm/Transforms/CodeGenPrepare/*::opt, tests/imported/llvm/Transforms/LoopStrengthReduce/*::opt, tests/imported/llvm/Transforms/ExpandMemCmp/*::opt, tests/imported/llvm/Transforms/AtomicExpand/*::opt, tests/imported/llvm/Transforms/PreISelIntrinsicLowering/*::opt, tests/imported/llvm/Transforms/PartiallyInlineLibCalls/*::opt, tests/e2e/O2/*::isel-ir, tests/function/O2/*::isel-ir, tests/e2e/pipeline/*::isel-ir, tests/function/pipeline/*::isel-ir

## Layer 4: interprocedural and whole-program optimization

### L4.function-attrs — FunctionAttrs, InferFunctionAttrs
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/FunctionAttrs/*::opt, tests/imported/llvm/Transforms/InferFunctionAttrs/*::opt

### L4.inline — The inliner and its cost model
- deps: L4.function-attrs
- exit: tests/imported/llvm/Transforms/Inline/*::opt

### L4.globals — GlobalOpt, GlobalDCE, ConstantMerge, StripDeadPrototypes, EliminateAvailableExternally
- deps: L3.instsimplify
- exit: tests/imported/llvm/Transforms/GlobalOpt/*::opt, tests/imported/llvm/Transforms/GlobalDCE/*::opt, tests/imported/llvm/Transforms/ConstantMerge/*::opt, tests/imported/llvm/Transforms/StripDeadPrototypes/*::opt, tests/imported/llvm/Transforms/EliminateAvailableExternally/*::opt

### L4.ipo-args — ArgumentPromotion, DeadArgElim, Internalize
- deps: L4.function-attrs
- exit: tests/imported/llvm/Transforms/ArgumentPromotion/*::opt, tests/imported/llvm/Transforms/DeadArgElim/*::opt, tests/imported/llvm/Transforms/Internalize/*::opt

### L4.phase-ordering — LLVM's whole-pipeline regression tests
- deps: L4.inline, L3.vectorize
- exit: tests/imported/llvm/Transforms/PhaseOrdering/*::opt

### L4.pipeline-O2 — `opt -O2` on clang's pre-optimization IR matches exactly
- deps: L4.phase-ordering
- exit: tests/e2e/pipeline/*::opt, tests/function/pipeline/*::opt

### L4.pipeline-run — Our opt -O2 + our llc -O2, run end to end
- deps: L4.pipeline-O2, L2.all
- exit: tests/e2e/pipeline/*::run, tests/function/pipeline/*::run

### L4.lto — Multi-module programs: llvm-link, then `-passes='lto<O2>'` (needs harness support for multi-file tests first)
- deps: L4.pipeline-O2
- exit: tests/lto/*::opt, tests/lto/*::run

## Layer 5: backend optimization (measured, not matched)

### L5.harness-perf — Add a benchmark mode to the harness (runtime vs `llc -O2`), and a unit per optimization
- deps: L2.all
- exit: tests/perf/*::perf
