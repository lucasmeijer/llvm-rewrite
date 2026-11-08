# InstCombine compare tests can't validate a compare port: they need a per-function differential check

- **Date / implementation / unit:** 2026-11-12 / goose / L1.instcombine.cmp
- **What happened:** after porting all of InstCombineCompares.cpp, only 22/77 cmp `::opt` tests pass: every
  test file also contains functions that need select/phi/store/GEP/and/xor visitors (other agents' units), and
  the first unported visitor in a file fails the whole file loudly. The unit's exit selector therefore measures
  the other visitors, not compares. `-goose-ic-lenient` (unported visitors are no-ops) produced mostly noise:
  differences caused by the missing visitors, indistinguishable from real compare bugs.
- **Time or effort lost:** ~1 h reading lenient diffs that were all other files' folds.
- **What would have helped:** a harness mode that splits a test into one module per function
  (`llvm-extract --func`) and compares each function where our opt exits 0. I wrote it as a throwaway script
  (/tmp/icc/perfn.py): 1537 icmp/fcmp functions identical, it found the one real compare bug in minutes
  (isSignTest mutating its predicate argument), and 14 silent bugs in other areas across InstCombine.
- **What you did instead:** the script above plus `sweep`. Suggest `./harness/run sweep --per-function`.
- Also: `git push origin HEAD:main` while a rebase is stopped on a conflict "succeeds" (HEAD is upstream's
  commit), which looks like a successful push of your work. Worth a line in the finish checklist.
