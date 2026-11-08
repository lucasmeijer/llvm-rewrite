# L1.instcombine.cmp can't be completed by porting InstCombineCompares.cpp alone

- **Date / implementation / unit:** 2026-11-08 / jai / L1.instcombine.cmp
- **What happened:** I ported all of InstCombineCompares.cpp (about 5000 lines of Jai). The unit went from 2/77 to
  37/77 `::opt` (L1.instcombine.arith from 48 to 60). Every one of the remaining 40 failures needs another visitor
  (select, and/or/xor, shifts, casts, calls, phi, freeze, gep, vector ops) that other agents are porting at the same
  time. Most icmp tests contain a few functions that rely on those visitors, so a file passes only when every
  visitor is done. The exit selector can't report progress on the compare port itself.
- **Time or effort lost:** about an hour triaging failures function by function, to tell my bugs from other
  visitors' gaps. With no `-debug-only=instcombine` in the release oracle, I had to replay LLVM's fold order by
  hand from the source.
- **What would have helped:**
  - A per-function comparison mode in the harness (`show`/`sweep`) that lists which functions differ and which
    opcodes their input contains, so "only uses complete visitors" can be filtered out automatically.
  - An assertions/debug build of opt (`-debug-only=instcombine`, which prints every fold) for replaying worklist
    order.
- **What you did instead:**
  - A throwaway script that flags differing functions whose input uses only opcodes with fully ported visitors.
    It found one real bug.
  - A random differential fuzzer (arith ops feeding one icmp or fcmp). It found the APFloat convert exactness bug.
    Both are described in impl/jai/NOTES.md.
