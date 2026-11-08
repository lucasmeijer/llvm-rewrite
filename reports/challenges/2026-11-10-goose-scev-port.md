# Porting ScalarEvolution: a 16k-line file in one recursive cycle, and the shared-file churn around it

- **Date / implementation / unit:** 2026-11-10 / goose / L1.analysis.scev, L1.analysis.loops (+ loop pass manager)
- **What happened:**
  - The unit is "port ScalarEvolution.cpp", which is ~16.5k lines whose builders are one big mutually recursive
    cycle. In Goose a function in a recursive cycle may not hold a growable local across a call into the cycle,
    so every `SmallVector<SCEVUse>` became a run on a shared scratch stack with the convention "the callee
    consumes `ss[b..]`". That convention is easy to get subtly wrong: three of the hardest bugs were two scratch
    stacks indexed in parallel while a nested call pushed onto only one of them, and a nested traversal searching
    the whole visited stack instead of its own part. Each produced *silently wrong* SCEVs, not crashes.
  - While I worked, the shared APInt changed from a fixed 4-word value to a pooled representation that is freed
    after every pass. SCEV caches ranges across passes, so cached wide APInts would dangle. I found this only
    by reading the new header after a rebase; nothing failed loudly.
  - Several output differences came from shared ValueTracking code (KnownBits shl/fshr edge cases, a missing
    `hasNonNullAttr` dereferenceable rule, no AllowEphemerals) and from the printer (metadata numbering for
    intrinsics with metadata operands). They don't show up in their owners' tests but do in SCEV's ranges.
  - The unit's corpus has only 247 `print<scalar-evolution>` lines; the real confidence came from sweeping
    `print<scalar-evolution>` over all 7000 imported/e2e files against LLVM, which found ~20 more bugs (including
    the FoldCache invalidation and the scan-limit off-by-one). I wrote that sweep as throwaway shell in /tmp.
- **Time or effort lost:** about a fifth of the session on scratch-stack bugs and on the APInt migration after a
  rebase; the sweep itself was cheap (90 s on 16 cores).
- **What would have helped:**
  - A harness command `./harness/run sweep --impl X --analysis 'print<...>' [dirs]` that compares an analysis
    printer (or `-S` output of a pass) against LLVM over every file of the corpus in parallel, reporting
    "loud failures" and "silent mismatches" separately. Silent mismatches are the dangerous class, and the unit
    exit selectors don't measure them.
  - A rule that changes to a shared representation (like APInt's lifetime) are announced to the other agents
    of the same implementation, with what callers must change.
  - Splitting the unit: "SCEV expression builders + printer without loops" and "backedge-taken counts + loop
    guards" would have given a checkpoint halfway.
- **What you did instead:** mark-based scratch stacks documented in DESIGN.md §8.7, cached ranges stored as IR
  constants, small fixes in the shared ValueTracking files (messaged to their owner), and the throwaway sweep.
