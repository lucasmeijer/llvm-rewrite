# Skipped while importing llvm/test/Transforms/Scalarizer (llvmorg-23.1.5)

38 of 39 files imported. Regenerate with `./harness/run import-llvm Transforms/Scalarizer`.

- `pass-param-parse-errors.ll` RUN `not opt -passes='scalarizer<unknown>' -disable-output %s 2>&1 | FileCheck -check-prefix=UNKNOWNERR %s`: not an opt invocation
- `pass-param-parse-errors.ll` RUN `not opt -passes='scalarizer<;>' -disable-output %s 2>&1 | FileCheck -check-prefix=UNKNOWNERR %s`: not an opt invocation
- `pass-param-parse-errors.ll` RUN `not opt -passes='scalarizer<min-bits=>' -disable-output %s 2>&1 | FileCheck -check-prefix=MINBITS-EMPTY-ERR %s`: not an opt invocation
- `pass-param-parse-errors.ll` RUN `not opt -passes='scalarizer<min-bits=x>' -disable-output %s 2>&1 | FileCheck -check-prefix=MINBITS-NOTINT-ERR %s`: not an opt invocation
- `pass-param-parse-errors.ll` RUN `not opt -passes='scalarizer<no-min-bits=10>' -disable-output %s 2>&1 | FileCheck -check-prefix=UNKNOWNERR %s`: not an opt invocation
