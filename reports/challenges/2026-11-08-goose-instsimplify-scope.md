# L1.instsimplify is really "port all of ValueTracking + ConstantFolding", and wide integers block ~20 tests

- **Date / implementation / unit:** 2026-11-08 / goose / L1.instsimplify
- **What happened:** The unit's exit selector is the whole imported InstSimplify directory (249 tests). Passing it
  meant porting more than InstructionSimplify.cpp: all of computeKnownBits, computeKnownFPClass +
  KnownFPClass, isKnownNonZero / isKnownToBeAPowerOfTwo / isKnownNonEqual / ComputeNumSignBits,
  poison/undef analysis, the AssumptionCache, isImpliedCondition (icmp and fcmp), ConstantRange,
  part of ConstantFPRange, Analysis/ConstantFolding with a DataLayout (loads at offsets, call folding), and
  exact IEEE arithmetic. That is about 9 new files and over 10k lines of Goose. The biggest remaining category is
  integers wider than 64 bits (about 20 tests). These tests mix one i80/i128/i1024 function into an otherwise
  passing file, so a partial wide-int port gains nothing until it covers every analysis.
- **Time or effort lost:** A lot of time was spent on rework after another agent's merge (77b3349, a rebase
  done by this agent) reverted sroa.goose and other files. Detecting and restoring that took about an hour.
  The rest of the effort was the inherent size of the port.
- **What would have helped:** (1) Split the roadmap unit: "ValueTracking core" (knownbits/nonzero/poison),
  "FP class analysis", "ConstantFolding with DL", "InstSimplify proper", each with its own test selector.
  (2) An early, shared decision on APInt width for the Goose implementation. Right now three widths coexist
  (64-bit KB/CR, 128-bit constfold, and goose_sccp's new 128-bit ConstantRange). (3) A harness/push guard that refuses a
  push whose diff touches files outside the pusher's declared set. I wrote one locally (/tmp/push.sh with a file
  whitelist) after the accident.
- **What you did instead:** Every unported path fails loudly with a specific "not ported" message, so
  `/tmp/fails.sh` (it groups failure messages by count) gave a reliable priority list. The local push script
  with a file whitelist should become standard (a `harness` option?).
