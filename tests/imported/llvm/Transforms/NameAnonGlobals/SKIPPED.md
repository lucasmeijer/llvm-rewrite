# Skipped while importing llvm/test/Transforms/NameAnonGlobals (llvmorg-23.1.5)

1 of 1 files imported. Regenerate with `./harness/run import-llvm Transforms/NameAnonGlobals`.

- `rename.ll` RUN `opt -passes='thinlto-pre-link<O0>,require<module-summary>' -o %t.bc < %s`: writes to a file
