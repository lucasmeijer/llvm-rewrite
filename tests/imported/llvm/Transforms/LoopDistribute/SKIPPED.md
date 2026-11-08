# Skipped while importing llvm/test/Transforms/LoopDistribute (llvmorg-23.1.5)

24 of 29 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopDistribute`.

- `basic-with-memchecks.ll` RUN `opt -aa-pipeline=basic-aa -passes='loop-distribute,print<access-info>' -enable-loop-distribute -verify-loop-info -verify-dom-info -disable-output < %s 2>&1 | FileCheck %s --check-prefix=ANALYSIS`: analysis printer (stderr output) not supported yet
- `basic.ll` RUN `opt -aa-pipeline=basic-aa -passes='loop-distribute,print<access-info>' -enable-loop-distribute -verify-loop-info -verify-dom-info -disable-output < %s 2>&1 | FileCheck %s --check-prefix=ANALYSIS`: analysis printer (stderr output) not supported yet
- `debug-loc.ll`: REQUIRES asserts
- `debug-print.ll`: REQUIRES asserts
- `diagnostics-with-hotness.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S -pass-remarks-missed=loop-distribute -pass-remarks-analysis=loop-distribute -pass-remarks-with-hotness < %s 2>&1 | FileCheck %s --check-prefix=HOTNESS`: diagnostic output flag -pass-remarks-missed=loop-distribute
- `diagnostics-with-hotness.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S -pass-remarks-missed=loop-distribute -pass-remarks-analysis=loop-distribute < %s 2>&1 | FileCheck %s --check-prefix=NO_HOTNESS`: diagnostic output flag -pass-remarks-missed=loop-distribute
- `diagnostics-with-hotness.ll` RUN `opt -passes='loop-simplify,require<aa>,loop-distribute' -S -pass-remarks-missed=loop-distribute -pass-remarks-analysis=loop-distribute -pass-remarks-with-hotness < %s 2>&1 | FileCheck %s --check-prefix=HOTNESS`: diagnostic output flag -pass-remarks-missed=loop-distribute
- `diagnostics-with-hotness.ll` RUN `opt -passes='loop-simplify,require<aa>,loop-distribute' -S -pass-remarks-missed=loop-distribute -pass-remarks-analysis=loop-distribute < %s 2>&1 | FileCheck %s --check-prefix=NO_HOTNESS`: diagnostic output flag -pass-remarks-missed=loop-distribute
- `diagnostics.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S < %s 2>&1 | FileCheck %s --check-prefix=ALWAYS --check-prefix=NO_REMARKS`: redirects or chains commands
- `diagnostics.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S -pass-remarks-missed=loop-distribute < %s 2>&1 | FileCheck %s --check-prefix=ALWAYS --check-prefix=MISSED_REMARKS`: diagnostic output flag -pass-remarks-missed=loop-distribute
- `diagnostics.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S -pass-remarks-analysis=loop-distribute < %s 2>&1 | FileCheck %s --check-prefix=ALWAYS --check-prefix=ANALYSIS_REMARKS`: diagnostic output flag -pass-remarks-analysis=loop-distribute
- `diagnostics.ll` RUN `opt -passes=loop-simplify,loop-distribute -enable-loop-distribute -S -pass-remarks=loop-distribute < %s 2>&1 | FileCheck %s --check-prefix=ALWAYS --check-prefix=REMARKS`: diagnostic output flag -pass-remarks=loop-distribute
- `no-reprocess.ll`: REQUIRES asserts
