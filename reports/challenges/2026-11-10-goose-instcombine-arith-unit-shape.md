# L1.instcombine.arith can't be completed without most of the rest of InstCombine

- **Date / implementation / unit:** 2026-11-10 / goose / L1.instcombine.arith
- **What happened:** The unit's exit tests are LLVM's add/sub/mul/div/rem test files, but each file is one
  `::opt` check over many functions, and those functions are full of `icmp`, `select`, `and`/`or`/`xor`, PHIs,
  min/max intrinsics, loads/GEPs and libcalls. Every instruction InstCombine visits must be handled exactly (or,
  per the fail-loudly rule, stop the run), so a test passes only when *every* visitor it reaches is ported. After
  porting the framework plus add/sub/mul/div/rem, shifts, integer casts, assume and calls, 11/115 arith tests pass;
  a lenient experiment (unported visitors do nothing) showed 25 would pass with only those visitors, and the rest
  need icmp (34 tests), and (16), select (12), or/xor (14) — i.e. the bitwise, cmp and select units, which the
  roadmap lists as *depending on* arith.
- **Time or effort lost:** No time lost going in circles, but the unit is far larger than its name: about 9k
  lines of Goose so far (framework 3k, visitors 6k) for 11 tests, and finishing it means porting InstCombineCompares
  (9.4k lines of C++), InstCombineSelect (5.4k) and InstCombineAndOrXor (5.7k) as well.
- **What would have helped:** Exit selectors for the InstCombine sub-units that pick *functions* rather than files
  (e.g. tests split per function, or a harness mode that compares only named functions), or an explicit first
  unit "InstCombine framework + the tests that only touch the arith visitors". A `-goose-ic-lenient`-style
  harness report ("would pass if visitor X existed") made the dependency structure visible; something like it
  could be a harness feature.
- **What you did instead:** Ported the framework faithfully and the arith-related files, plus whatever cheap
  generic visitors many tests reach (casts, shifts, assume, calls); wrote `tools/ic_failures.py` to rank blockers,
  and documented how to add visitors (DESIGN.md §12) so the cmp/select/bitwise sub-units can be worked in parallel
  on the same framework.
