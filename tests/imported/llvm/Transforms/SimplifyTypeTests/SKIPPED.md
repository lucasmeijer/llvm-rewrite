# Skipped while importing llvm/test/Transforms/SimplifyTypeTests (llvmorg-23.1.5)

1 of 1 files imported. Regenerate with `./harness/run import-llvm Transforms/SimplifyTypeTests`.

- `basic.ll` RUN `sed -e 's/"_ZTSFvvE"/"wrongtype"/g' %s | opt -S -passes=simplify-type-tests | FileCheck --check-prefix=WRONGTYPE %s`: not an opt invocation
