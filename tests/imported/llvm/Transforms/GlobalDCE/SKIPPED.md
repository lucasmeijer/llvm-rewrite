# Skipped while importing llvm/test/Transforms/GlobalDCE (llvmorg-23.1.5)

33 of 34 files imported. Regenerate with `./harness/run import-llvm Transforms/GlobalDCE`.

- `2009-01-05-DeadAliases.ll` RUN `opt < %s -passes=globaldce -S > %t`: redirects or chains commands
- `2009-01-05-DeadAliases.ll` RUN `FileCheck %s < %t`: not an opt invocation
- `2009-01-05-DeadAliases.ll` RUN `FileCheck --check-prefix=DEAD %s < %t`: not an opt invocation
