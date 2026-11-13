# Empty stub transforms in a partial port turn into silent mismatches once a feature further up is ported

- **Date / implementation / unit:** 2026-11-13 / goose / L1.vectorize.loop
- **What happened:** the earlier LoopVectorize port had empty bodies for VPlan transforms that "could not apply yet"
  (`hoistPredicatedLoads`, `sinkPredicatedStores`, `narrowInterleaveGroups`, `truncateToMinimalBitwidths`), because
  the inputs that would reach them failed loudly earlier. Porting interleave groups made `narrowInterleaveGroups`
  reachable and porting predication made the hoist/sink pair reachable; both stubs then silently produced different
  IR (found by goose_o2pipeline's -O2 sweep and by my own `--passes loop-vectorize` sweep, not by any unit test).
  Similarly a `c_int(<vector type>, -1)` in an existing VPInstruction::Not lowering only showed up once if-conversion
  produced vector `not`s.
- **Time or effort lost:** small (an hour), because the sweeps were run after every milestone; without them both
  would have been pushed as passing work.
- **What would have helped:** a convention that an unported transform is never an empty function: it must check
  whether it would act and fail loudly (`vp_unported`), like the rest of the port does. A grep-able marker for
  "trivially empty because unreachable today" would also have made the audit quick.
- **What you did instead:** ported the four transforms fully, and kept running the four sweeps plus the -O2-input
  comparison (`scripts/o2_lv_inputs.py --compare`, now shared in scripts/ together with `scripts/lv_cost_compare.py`)
  after each feature. Running the -O2 comparison per milestone is cheap (10 s for 919 modules) and should be the
  default loop for LoopVectorize work.
