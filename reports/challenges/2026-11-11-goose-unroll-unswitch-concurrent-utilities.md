# Two units in one task, written while two other agents ported overlapping loop utilities

- **Date / implementation / unit:** 2026-11-11 / goose / L1.loop-unroll + L1.unswitch
- **What happened:** the task bundled LoopUnroll (pass, analyzer, UnrollLoop, runtime remainder, peeling) with
  SimpleLoopUnswitch and a reusable ValueMapper/CloneFunction for a future inliner — roughly 12k lines of LLVM. At the
  same time goose_loopmisc wrote `loop_utils.goose` (LoopInfo::erase, SplitBlock/SplitEdge, breakLoopBackedge,
  LoopBlocksDFS) and goose_inline started on the inliner. My first rebase failed to build because both files used the
  `lu_` prefix (Goose has one global function namespace); LoopInfo::erase, SplitBlock and changeToUnreachable now
  exist twice (`unroll_utils.goose` and `loop_utils.goose`), and loop_versioning.goose has its own CloneBasicBlock.
- **Time or effort lost:** ~30 min on prefix clashes and on a port-progress.txt line that another agent had already
  added for CloneFunction.cpp; the duplicated utilities will cost a later merge.
- **What would have helped:** a short list in impl/<lang>/NOTES.md of "shared LLVM utilities and who owns them"
  (LoopInfo update API, BasicBlockUtils split/merge, Local.cpp deletion helpers, ValueMapper), so the first agent to
  need one ports it into the agreed file and the others wait or import; and a reserved function-name prefix per file
  (Goose fails only at link-like resolution time, after a 2-4 minute build).
- **What you did instead:** renamed my prefixes (`lup_`, `ul_`, `uu_`, `slu_`), reused loop_utils.goose's
  containsIrreducibleCFG / RecursivelyDeleteTriviallyDeadInstructions-with-MSSAU in the unswitcher, and noted the
  duplicates in NOTES.md. Also: the X86 cost model's CPU table has only six CPUs, so most `-mcpu=` tests of both units
  (and many sweep runs with test flags) fail loudly; extending gen_x86costs.py to every Proc/ProcModel (foreach,
  !listremove) is a separate, shared piece of work that no unit owns.
