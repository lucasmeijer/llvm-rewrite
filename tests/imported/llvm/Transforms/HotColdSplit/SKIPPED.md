# Skipped while importing llvm/test/Transforms/HotColdSplit (llvmorg-23.1.5)

40 of 51 files imported. Regenerate with `./harness/run import-llvm Transforms/HotColdSplit`.

- `apply-noreturn-bonus.ll`: REQUIRES asserts
- `apply-penalty-for-inputs.ll`: REQUIRES asserts
- `apply-penalty-for-outputs.ll`: REQUIRES asserts
- `apply-successor-penalty.ll`: REQUIRES asserts
- `assumption-cache-invalidation.ll`: REQUIRES asserts
- `outline-inner-region.ll`: target triple powerpc64-ibm-aix7.2.0.0
- `outline-outer-region.ll`: target triple powerpc64-ibm-aix7.2.0.0
- `section-splitting-custom.ll` RUN `opt -passes=hotcoldsplit -hotcoldsplit-threshold=-1 -pass-remarks=hotcoldsplit -enable-cold-section=true -hotcoldsplit-cold-section-name="__cold_custom" -S < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=hotcoldsplit
- `section-splitting-default.ll` RUN `opt -passes=hotcoldsplit -hotcoldsplit-threshold=-1 -pass-remarks=hotcoldsplit -enable-cold-section=true -S < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=hotcoldsplit
- `split-cold-2.ll` RUN `opt -passes=hotcoldsplit -hotcoldsplit-threshold=-1 -pass-remarks=hotcoldsplit -S < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=hotcoldsplit
- `stale-funcretval-after-sever.ll`: target triple arm64-apple-macosx27.0.0
