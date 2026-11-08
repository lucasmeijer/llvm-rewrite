# InstCombine bitwise: the unit's tests can't tell a correct port from a wrong one; attributing a diff took most of the time

- **Date / implementation / unit:** 2026-11-08 / jai / L1.instcombine.bitwise (and L1.instcombine.arith)
- **What happened:** I ported InstCombineAndOrXor.cpp (5.7k lines) and InstCombineShifts.cpp (2k lines) in full,
  plus Local.cpp's bswap/bitreverse recognizer. The unit went from 13/86 to 53/86 ::opt checks. Every remaining
  failure I looked at comes from another visitor that isn't ported (casts: `zext (trunc X)`, `trunc (lshr X, C) to
  i1`; calls: fshl/fshr amounts, `range` attributes, min/max; vector ops; foldVectorBinop). An imported test file
  is one ::opt check covering 20-100 functions, so a single unported fold elsewhere fails the whole file. The
  harness can't say whether the remaining diffs are mine.
- **Time or effort lost:** about a third of the session went on attribution, not porting. For each diff I had to
  work out which visitor LLVM used, with no `-debug` in the release opt. Two cases took over 20 minutes each:
  - `icmp ne (and (lshr X, 4), 1), 0`: LLVM gets there through visitTrunc after the icmp fold.
  - an `smin` named `%1` vs `%res`: LLVM's select visitor takes a different path.
- **What would have helped:**
  1. A per-function mode in the harness for `::opt` (split with `llvm-extract`, compare per function, report
     "N/M functions identical"). Progress inside a big test file would then be visible, and the functions whose
     bodies only use already-ported opcodes would point straight at real bugs. I wrote this as a throwaway script
     (`/tmp/fz/funcdiff.py`); it found every real bug I fixed:
     - shared matchers: `m_SpecificInt` accepted poison lanes, `m_ConstantInt(uint64&)` rejected splats;
     - `andIRFlags` dropped nneg/samesign/trunc flags;
     - two IRBuilder default names;
     - an out-of-bounds `op()` in ic_compares.jai.
  2. An LLVM opt build with `-debug-only=instcombine` (assertions build) in the workspace. "IC: Visiting / Old =
     / New =" traces would turn the attribution work above into a quick lookup.
  3. Splitting the InstCombine sub-units by test *function* rather than by file prefix, or listing which other
     visitors each exit test needs.
- **What you did instead:** the per-function script, plus a random differential fuzzer (40k straight-line
  functions over and/or/xor/shifts/add/sub/icmp; no diffs left that come from these two files). Both are
  described in impl/jai/NOTES.md. For tracing I temporarily patched the jai driver to print each visit result,
  and reverted the patch.
