# Two traps in L1.extra.utility and analysis-misc: guess flags can't be swept, and Pass_Kind ran out of room

- **Date / implementation / unit:** 2026-11-25 / jai / L1.extra.utility, L1.extra.analysis-misc
- **What happened:**
  1. **Guess flags can't be swept.**
     - I added `-stack-safety-guess-address-order`, a flag of ours that guesses the pointer order LLVM would use.
     - I swept `print-stack-safety --extra='-stack-safety-guess-address-order'` to measure how good the guess is.
     - LLVM's opt rejects the unknown option, so all 10828 files came out `llvm-failed`.
     - The same happens for every `-<pass>-guess-address-order` flag. The sweep can't check a guess, and nothing
       warns about it up front.
  2. **`Pass_Kind` ran out of room.**
     - `Pass_Kind` in passes.jai was `enum u8`.
     - After rebasing onto main, the merged enum had 257 members. The build failed with "Numeric constant is out of
       range for this enum".
     - I had started the full `check --update` on that tree before building, and had to kill it.
     - I widened the enum to u16.
  3. **The split between `utility` and `analysis-misc` didn't match the code.**
     - The units are separate on the roadmap, but they share registration code (passes.jai, extras_b_cl.jai).
     - So they went in as one commit, like cfg-structurize and scalarizer before them.
- **Time or effort lost:**
  - One wasted sweep, about 10 minutes.
  - One check started on a tree that doesn't build, about 2 minutes.
- **What would have helped:**
  - `harness/run sweep --extra` could warn when LLVM fails on every file with "Unknown command line argument".
    That usually means an option only our implementation knows.
  - A comment at `Pass_Kind` saying it is near the u8 limit. Or u16 from the start.
  - Always building before starting a long check after a rebase. (The publish flow implies it; I skipped it.)
- **What I did instead:**
  - Guess flags are now tested only by hand.
  - `Pass_Kind` is `enum u16` (no layout depends on its size).
