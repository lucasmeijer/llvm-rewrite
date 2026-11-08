# Three agents porting InstCombine in parallel: shared files, mis-attributed sweep differs

- **Date / implementation / unit:** 2026-11-12 / goose / InstCombine FP visitors (L1.instcombine*), debugify
- **What happened:** goose_ic_fp, goose_ic_memory and goose_ic_calls worked on InstCombine at the same time. The
  dispatch (`ic.goose`), the builder (`ic_builder.goose`), `ic_common.goose` and `flags.goose` are touched by all
  of them; my first rebase hit a conflict in `ic_builder.goose` where both sides appended at the end of the file,
  and git's hunk boundaries split a function's closing brace, so a naive "take both sides" left a function
  unterminated (caught by the build, not by git). The per-function sweep is the main correctness signal, but its
  silent differs are reported per file, not per owner: the other agents and I each saw differs caused by another
  agent's code (fptoui-of-fdiv in the cast visitors, minnum operand order in ic_select) and sent each other
  messages about them.
- **Time or effort lost:** ~20 minutes on the conflict and on triaging differs to the right owner; one early
  python-based edit of my own duplicated a file because `str.index` found a matching comment first.
- **What would have helped:** one file per agent for new code from the start (I did that for the FP visitors) and a
  rule that shared files only get small, separately pushed commits; a sweep option that prints, per silent
  differ, the `ic_*.goose` files whose functions were on the stack (or simply the first `fold`/`visit` that fired)
  so attribution doesn't need a manual reduction.
- **What you did instead:** pushed the shared builder helpers early and announced their names; reduced each differ
  to a 3-line input before messaging its owner.
