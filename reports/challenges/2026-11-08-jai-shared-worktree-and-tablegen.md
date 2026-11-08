# Shared working tree blocks `git pull --rebase`; no TableGen output for intrinsic attributes

- **Date / implementation / unit:** 2026-11-08 / jai / L0.design, L0.print-basic, L0.print-clang
- **What happened:** (1) All agents share one checkout of /work. The first `git pull --rebase` after committing
  `impl/jai/DESIGN.md` failed with "cannot pull with rebase: You have unstaged changes", because the harness agent
  had uncommitted edits in `harness/lrh/*.py` and an untracked `tests/analysis/`. AGENTS.md's finish steps
  (`commit`, `pull --rebase`, rerun, push) assume a private tree. (2) Round-tripping any intrinsic declaration needs
  `Intrinsic::getAttributes`, which LLVM generates with TableGen from `Intrinsics*.td`; the workspace has neither
  TableGen nor its generated `.inc` files, and `parseFnAttributeValuePairs` etc. silently differ without them
  (`; Function Attrs:` lines and `attributes #N` groups change for every intrinsic).
- **Time or effort lost:** a few minutes for (1); about half an hour for (2) (writing a generator, then discovering
  that some intrinsics have explicit names such as `int_vastart` = `llvm.va_start`).
- **What would have helped:** (1) a line in AGENTS.md saying the tree is shared and to use
  `git pull --rebase --autostash` and to `git add` only your own paths; or one worktree per agent. (2) The generated
  `IntrinsicImpl.inc` / `Attributes.inc` from the LLVM build, kept next to the source in the image (they are build
  products of the pinned release, so as authoritative as the .td files).
- **What you did instead:** (1) `git pull --rebase --autostash`, committing only `impl/jai/` and my knowledge file.
  (2) `impl/jai/gen/gen_intrinsics.py` takes intrinsic names from the .td records and gets each intrinsic's
  attributes by running the oracle `opt` on one declaration found in `tests/`; intrinsics no test declares fail
  loudly. Other implementations will need the same table; the script's output could become a shared
  `knowledge/llvm/` data file if more implementations want it.
