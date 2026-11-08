# Skipped while importing llvm/test/Transforms/LCSSA (llvmorg-23.1.5)

20 of 22 files imported. Regenerate with `./harness/run import-llvm Transforms/LCSSA`.

- `avoid-intrinsics-in-catchswitch.ll` RUN `opt < %s -passes='debugify,function(loop-mssa(licm))'  -S -o /dev/null`: writes to a file
- `remove-phis.ll` RUN `opt < %s -passes=lcssa,verify -S -o /dev/null`: writes to a file
