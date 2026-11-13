# L2.lto needed harness design decisions nobody had made, and the "rerun on the rebased tree" rule races with other agents

- **Date / implementation / unit:** 2026-11-28 / jai (+ shared harness) / L2.lto, L2.link, L2.lto-passes
- **What happened:** The roadmap said L2.lto "needs harness support for multi-file tests first" and plan.md listed it
  as undecided, so the test format had to be designed inside an implementation task. I had to guess several things
  that change what "exact IR" means for every implementation:
  1. *What the post-link command is.* `opt -passes='lto<O2>'` on a linked module keeps every external symbol, so
     cross-module inlining can never delete a callee and the test would not resemble a real LTO build. A linker
     internalizes everything not visible outside the IR first. I chose `-passes='internalize,lto<O2>'
     -internalize-public-api-list=main` (documented in docs/testing.md); an LTO-resolution-based emulation would be
     more faithful but needs a symbol-resolution input format.
  2. *Isolation.* I made `::opt` start from LLVM's linked module (like `::isel-ir` starts from LLVM's opt output) and
     added a separate `::link` check, so a linker bug doesn't hide pipeline progress; `::run` uses only our tools.
  3. *Where the pre-link pipeline is tested.* Each TU is a normal test file with `@opt: -passes='lto-pre-link<O2>'`,
     so pre-link is an ordinary `::opt` check and the link step consumes LLVM's pre-link output.
  4. *What to import.* LLVM's own `test/Linker` (196 usable llvm-link RUN lines once `%t` files from `llvm-as` and
     `echo | llvm-as` are followed) turned out to be the best llvm-link test source, so I added an `L2.link` unit.
  Separately: after `--update` on the rebased tree, a final `git fetch && git rebase` before `git push` twice pulled
  in other agents' commits, so the pushed tree was not exactly the one checked (I reran the ratchet afterwards; it
  was green).
- **Time or effort lost:** about an hour on the format decisions (reading lib/LTO to justify internalize, checking
  that `clang -flto` equals disable-llvm-passes + lto-pre-link), little else. The race cost a rerun.
- **What would have helped:** an lplan round (or a short decision in plan.md) for multi-module tests before the unit
  was assigned; a note in AGENTS.md on what to do when the final pre-push rebase brings new commits (rerun only the
  ratchet? or loop until fetch is a no-op?).
- **What you did instead:** made the decisions above, wrote them into docs/testing.md ("Multi-module (LTO) tests")
  and plan.md, and added knowledge/llvm/linker-and-lto.md. Reviewers should confirm (1) in particular; changing the
  post-link line later only means regenerating `tests/lto/*/test.lto` with `from-c --force`.
