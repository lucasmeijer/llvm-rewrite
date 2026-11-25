# Skipped while importing llvm/test/DebugInfo/Generic/assignment-tracking (llvmorg-23.1.5)

63 of 68 files imported. Regenerate with `./harness/run import-llvm DebugInfo/Generic/assignment-tracking`.

- `sunk-addr.ll` RUN `llc -start-before=codegenprepare -stop-after=codegenprepare -mtriple=x86_64-unknown-unknown %s -o - | FileCheck %s --implicit-check-not="#dbg_"`: not an opt invocation
- `scalable-vector-memcpy.ll`: target triple riscv64-unknown-linux-gnu
- `set-flag-only-if-modified.ll` RUN `sed 's/;Uncomment-with-sed//g' < %s | opt -passes=declare-to-assign -S - -o - | FileCheck %s --check-prefix=WITH-INTRINSIC`: not an opt invocation
- `distinct.ll` @error `-passes=verify`: fails in the parser, not in the verifier
- `distinct.ll`: llvm opt rejects the file
- `operands.ll` @error `-passes=verify`: fails in the parser, not in the verifier
- `operands.ll`: llvm opt rejects the file
- `complex.ll`: target triple armv7-apple-unknown
