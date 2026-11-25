# Profiles: sample profile loader, IR PGO helpers, profile-check passes

Verified against LLVM 23.1.5 (sources under llvm/lib/Transforms/IPO/SampleProfile*.cpp, llvm/lib/ProfileData/,
llvm/lib/Transforms/Instrumentation/, llvm/lib/Transforms/Utils/ProfileVerify.cpp) and the tests named below.

## Sample profile loader

- `getCanonicalFnName(const Function &F)` reads the `sample-profile-suffix-elision-policy` attribute; when it is
  absent the attribute value is `""`, which means "all": the name is cut at the **first** `.` (`use.i1` -> `use`).
  The StringRef overload defaults to `"selected"` (strips only `.llvm.`, `.part.`, `.__uniq.` suffixes). Both are
  used in different places (SampleProfileMatcher's callee anchors use the StringRef form).
- The loader's SymbolMap is filled while iterating the module's value symbol table (StringMap order). If a
  function's stripped name is another function's name, the entry ends up as that function or nullptr depending
  on the iteration order (SampleProfile.cpp, runOnModule, the `SymbolMap.emplace` / `r.first->second = nullptr`).
- A pseudo-probe-based profile turns on `-salvage-stale-profile` and `-salvage-unused-profile` unless given
  (doInitialization), so every probe profile runs the SampleProfileMatcher.
- `SampleProfileReader::read(FuncsToUse)` returns `not_implemented` for the text format; the matcher's
  functionMatchesProfileHelper then returns false (no call-graph match through an unloaded text profile).
- Ext-binary profiles: the loader sets the module before reading, so only the profiles of the module's functions
  (canonical names, looked up by MD5 in the function offset table) are read. `FuncOffsetTable::lookup` returns
  `std::optional<uint64_t>`: offset 0 is a hit.
- `SampleProfileReaderGCC::hasFormat` compares the buffer *as a C string* with `"adcg*704"` (the version word
  follows, then NUL bytes). GCOV version `*704` read little-endian is `407*`, i.e. V407, the only one accepted.
- `setProbeDistributionFactor` computes `IntFactor *= Factor` with `IntFactor = UINT64_MAX` in float:
  `(float)UINT64_MAX` is 2^64, times 0.5 is 2^63 (tests/imported/llvm/Transforms/SampleProfile/pseudo-probe-update-2.ll).
- Pseudo probes (SampleProfileProber::computeProbeId) skip `isa<IntrinsicInst>` calls only; an `invoke` of an
  intrinsic is not an IntrinsicInst and gets a call probe (counted in the hash's call count).

## Pipelines with -pgo-kind=pgo-sample-use-pipeline

- opt builds `PGOOptions(ProfileFile = -profile-file, ..., SampleUse)`; `-sample-profile-file` still works because
  SampleProfileLoaderPass falls back to it when the file name is empty.
- buildModuleSimplificationPipeline: the loader runs right after the early function simplification, followed by
  `require<profile-summary>` and (not in LTO pre-link) `pgo-icall-prom` with InLTO = SamplePGO = true;
  `pgo-force-function-attrs` before always-inline; in ThinLTO post-link with `-flattened-profile-used` the
  profile is not reloaded and the early ICP runs instead. The inliner gets HotCallSiteThreshold = 0 in LTO
  pre-link, and every PGOOptions sets InlineParams::EnableDeferral = `-enable-npm-pgo-inline-deferral` (true).
  Full unrolling is dropped from the function simplification pipeline in ThinLTO pre-link.

## IR PGO helpers

- `InstrProfSymtab::finalizeSymtab` sorts MD5FuncMap with an unstable `llvm::sort(less_first)`: with two different
  functions of one MD5 the `getFunction` result is order dependent.
- `ICallPromotionAnalysis::getPromotionCandidatesForInstruction` reads at most `-icp-max-prom` (3) value-profile
  entries; `updateFuncValueProfiles` re-annotates with MaxMDCount = NumCandidates.
- PGOMemOPSizeOpt clears and re-annotates the memop's `!prof` *before* cloning it into the case blocks, so the
  clones carry the remaining value profile.

## prof-inject / prof-verify (ProfileVerify.cpp)

- BranchProbability's denominator is always 2^31, so the injected weights are numerator / gcd(numerators).
- `LLVMContext::emitError` under opt: the message is printed as `error: <msg>` and opt continues; after the pass
  pipeline NewPMDriver checks `HasErrors` and exits 1 without writing the output.
