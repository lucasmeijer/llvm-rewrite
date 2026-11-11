# Skipped while importing llvm/test/Transforms/FunctionSpecialization (llvmorg-23.1.5)

59 of 62 files imported. Regenerate with `./harness/run import-llvm Transforms/FunctionSpecialization`.

- `function-specialization-implicit-ref.ll` RUN `opt -passes="ipsccp<func-spec>" -S -force-specialization < %s 2>&1 | FileCheck %s`: redirects or chains commands
- `function-specialization-stats.ll`: REQUIRES asserts
- `recursive-penalty.ll`: REQUIRES asserts
