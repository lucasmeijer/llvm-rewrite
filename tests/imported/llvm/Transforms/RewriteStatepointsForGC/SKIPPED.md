# Skipped while importing llvm/test/Transforms/RewriteStatepointsForGC (llvmorg-23.1.5)

69 of 71 files imported. Regenerate with `./harness/run import-llvm Transforms/RewriteStatepointsForGC`.

- `phi-vector-bitcast.ll`: REQUIRES asserts
- `unsupported-gc-error.ll` RUN `not --crash opt -disable-output -passes=rewrite-statepoints-for-gc %s 2>&1 | FileCheck %s`: not an opt invocation
