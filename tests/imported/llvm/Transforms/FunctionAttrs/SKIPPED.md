# Skipped while importing llvm/test/Transforms/FunctionAttrs (llvmorg-23.1.5)

51 of 57 files imported. Regenerate with `./harness/run import-llvm Transforms/FunctionAttrs`.

- `convergent.ll`: uses non-x86 target intrinsic @llvm.nvvm.
- `invalidate.ll` RUN `opt -passes='function(require<no-op-function>),cgscc(function-attrs)' -disable-output < %s -debug-pass-manager 2>&1 | FileCheck %s`: diagnostic output flag -debug-pass-manager
- `make-buffer-rsrc.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `mismatched-signature-invalidation.ll` RUN `opt -disable-output -passes="function(print<memoryssa>),cgscc(function-attrs),function(print<memoryssa>)" < %s 2>&1 | FileCheck %s`: analysis printer (stderr output) not supported yet
- `sendmsg-nocallback.ll`: uses non-x86 target intrinsic @llvm.amdgcn.
- `stats.ll`: REQUIRES asserts
