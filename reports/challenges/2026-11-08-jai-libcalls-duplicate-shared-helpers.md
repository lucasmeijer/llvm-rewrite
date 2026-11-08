# Two parallel agents ported the same ValueTracking helpers (getConstantDataArrayInfo / GetStringLength)

- **Date / implementation / unit:** 2026-11-08 / jai / library-call simplifier (InstCombine tryOptimizeCall)
- **What happened:** I ported getConstantDataArrayInfo, getConstantStringInfo and GetStringLength for
  SimplifyLibCalls. While I worked, /root/jai_ic_memory ported getConstantDataArrayInfo and GetStringLength into
  memory_builtins.jai (for getAllocSize of strdup). After rebasing, the build failed with "matches 2 possible
  overloads" (Jai procedure names are global). The two copies also differed: theirs treated an all-zero
  ReadByteArrayFromGlobal result as an array, LLVM (ConstantDataArray::get -> ConstantAggregateZero) as none.
  The same happened on a smaller scale with `pm_specific_fp`, `pm_constant_int_u64`, `dl_fits_in_legal_integer`,
  `is_constant_data`, `ap_eq_u64`, `AFK_*`: helpers I wrote because grep for the LLVM name found nothing, but
  that existed under a Jai name.
- **Time or effort lost:** ~20 minutes resolving the collision and comparing the two versions; a few build
  cycles for the smaller duplicates.
- **What would have helped:** a shared index "LLVM function -> Jai procedure" (e.g. a generated table from the
  `// LLVMName` comments above each procedure), or a rule that ValueTracking / Local.cpp / IRBuilder helpers go
  into one designated file per LLVM source file, so that two agents porting the same LLVM function end up editing
  the same file (and get a merge conflict instead of a silent duplicate).
- **What you did instead:** kept one copy (value_tracking_strings.jai, the faithful one), removed the other, told
  the other agent. I grepped for the LLVM CamelCase name in comments (`// getConstantStringInfo`) before writing
  each later helper, which found most existing ones.
