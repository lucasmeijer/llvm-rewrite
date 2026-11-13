# The IR Verifier and how opt runs it (LLVM 23.1.5)

Facts needed to reproduce the verifier's diagnostics byte for byte (`::error` checks, `docs/testing.md`). Verified
against `llvm/lib/IR/Verifier.cpp`, `tools/opt/optdriver.cpp`, `NewPMDriver.cpp`, `lib/IR/AutoUpgrade.cpp` and by
running opt on `tests/imported/llvm/Verifier` (229 failing and 179 passing RUN lines, all reproduced by the jai port
except parser gaps).

## When opt verifies

1. **While parsing** (`LLParser::validateEndOfModule` -> `UpgradeDebugInfo`), only when the module has the module
   flag `"Debug Info Version"` = 3: `verifyModule(M, &errs(), &BrokenDebugInfo)` — broken debug info is *not* an
   error there. The messages of every failed check (debug info or not) go to stderr. Broken IR ->
   `LLVM ERROR: Broken module found, compilation aborted!` (report_fatal_error: abort, crash backtrace, exit 134).
   Only broken debug info -> `warning: ignoring invalid debug info in <file>` (the module identifier, i.e. the path
   as given), then `StripDebugInfo`. Without the flag (or another version) the debug info is stripped without
   verification (`warning: ignoring debug info with an invalid version (N) in <file>` if anything was stripped).
2. **After parsing**, after `-strip-debug`, `-strip-named-metadata` and the `-mtriple` override, unless
   `-disable-verify`: `verifyModule(*M, &errs())` (debug info counts as an error now). Broken ->
   `<argv[0]>: <input>: error: input module is broken!` and exit 1. LLVM prints its argv[0]
   (`/opt/llvm-23.1.5/bin/opt: ...`), which is why the harness normalizes the tool prefix.
3. **At the end of the pipeline** (`VK != None`, also with `-verify-each`): `VerifierPass` ->
   `VerifierAnalysis` (`verifyModule(M, &dbgs(), &DebugInfoBroken)`; dbgs() is stderr) -> if IR *or* debug info is
   broken: `LLVM ERROR: Broken module found, compilation aborted!`.
4. `-passes=verify` (module) is the same VerifierPass; `function(verify)` runs `verifyFunction` (no module-level
   checks; debug info counts) -> `Broken function found, compilation aborted!`. `require<verify>` computes and caches
   VerifierAnalysis (prints, never aborts); a later VerifierPass reuses the cached result unless a pass invalidated
   it. `-verify-each` (StandardInstrumentations VerifyInstrumentation) verifies after every pass:
   `Broken function found after pass "<PassClassName>", compilation aborted!` (or `module`).
5. opt enables **ODR uniquing of debug types** (`Context.enableDebugTypeODRUniquing()` unless
   `--disable-debug-info-type-map`). That turns `verifyCompileUnits` ("DICompileUnit not listed in llvm.dbg.cu")
   off and the check "definition subprograms cannot be nested within DICompositeType when enabling ODR" on.

## How messages are printed

- `Check(C, msg, values...)` prints `msg\n` and then each value; it returns from the *visit method it is written
  in* only. Helpers called from a visit method (checkAtomicMemAccessSize, checkPtrToAddr, verifyFunctionAttrs,
  visitRangeMetadata, the `VerifyTypeAlign` lambda of visitCallBase, ...) return to their caller, which continues.
  Checks inlined in visitInstruction (`!fpmath`, `!nonnull`, `!align`, ...) skip the rest of it, including the
  insertion into InstsInThisBlock (so a later use in the block gets a dominance check).
- `Write(Value)`: an Instruction with `V.print(OS, MST)` (two-space indent, no debug records) + `\n`; anything
  else with `printAsOperand(OS, /*PrintType=*/true, MST)` + `\n` (`ptr @f`, `label %bb`, `i32 %x`).
  `Write(Type)` is `' ' << *T` with **no newline**, and `Type::print` of a named struct type includes its body:
  ` %ty = type { i32 }`. The next message then starts on the same line (e.g.
  ` [2147483648 x i16]opt: x.ll: error: input module is broken!`). `Write(Metadata)` is `MD->print(OS, MST, &M)`:
  `!N = <body>` (with `distinct `), an MDString `!"..."`, a ValueAsMetadata `i32 1`, a DIExpression inline.
  `Write(unsigned)` / APInt print the number and `\n`; a NamedMDNode prints `!name = !{...}\n` and Write adds
  another `\n`. Debug records print without the 4-space indent (`#dbg_value(...)`).
- **The verifier's ModuleSlotTracker `MST(&M)` initializes all metadata** (`ShouldInitializeAllMetadata` defaults to
  true, include/llvm/IR/ModuleSlotTracker.h:72): metadata numbers are the module printer's numbers (globals, named
  metadata, then every function's metadata in order), no matter what was printed before. Local slots are lazy:
  printing an instruction incorporates its function; `printAsOperand` does not, so an unnamed argument or block
  of a function none of whose instructions was printed yet comes out as `<badref>`.
- The convergence verifier prints values with `V->print(OS)` (a fresh slot tracker per value), cycles as
  `depth=N: entries(...) <blocks>`.
- `Intrinsic::isSignatureValid` writes its own message (lib/IR/Intrinsics.cpp `matchIntrinsicType` with
  `MatchPosition`): `intrinsic return type (overload type 0) expected any integer vector, but got <4 x float>`,
  `intrinsic argument 1 type (same vector width of overload type 0) expected vector with vscale x 4 elements
  (overload type 0 is <vscale x 4 x i32>), but got <4 x i32>`, `intrinsic has incorrect number of args. Expected
  3, but got 2`; the declaration is printed after it (`F.print(OS)`, a fresh slot tracker).

## Semantics that are easy to get wrong

- `CallBase::getIntrinsicID()` is the callee operand's intrinsic even when the call's function type differs;
  `getCalledFunction()` (and so `isa<IntrinsicInst>`, `isa<GCRelocateInst>`, ...) requires the types to match.
- `IntrinsicInst::mayLowerToFunctionCall` is true only for the ObjC ARC runtime intrinsics (objc.retain,
  objc.release, ...), not for memcpy/memset: the "Missing funclet token on intrinsic call" check only applies to
  those.
- `CastInst::castIsValid(BitCast)`: pointers may be bitcast to and from **byte** types (`b64`); otherwise pointer <->
  non-pointer is invalid, `<1 x ptr>` <-> `ptr` is valid.
- `StructType::isSized`: sized structs are cached, so the Visited set only rejects a struct that contains itself;
  `{ %A, %A }` is sized.
- `getParentPad`: a FuncletPadInst (catchpad / cleanuppad) keeps its parent as the **last** operand, a
  catchswitch as operand 0.
- `DominatorTree::dominates(Value*, Use&)` special-cases invoke (the normal edge) but not callbr.
- `ModuleSlotTracker`-independent: "GlobalValue with local linkage or non-default visibility must be dso_local!"
  can't fire for parsed IR (setLinkage / setVisibility set dso_local).
- AutoUpgrade of `llvm.dbg.*` calls to records: the location (operand 0) and a dbg.assign address are taken as any
  metadata (`unwrapMAVMetadataOp`), variable, expression, DIAssignID and label only if they are MDNodes
  (`unwrapMAVOp`); `metadata !""` as an expression becomes a null expression, which the verifier reports
  (`invalid #dbg record expression`, record printed with `(null)`).
- `StripDebugInfo` removes *all* `!dbg` attachments of a function (a function can have two parsed `!dbg`; the
  verifier reports "function must have a single !dbg attachment").
- `TBAAVerifier` caches base and scalar nodes per verifier; the struct-path walk of an access tag only depends on
  the tag, so a tag verified once needs no second walk (the per-instruction kind check still runs).
