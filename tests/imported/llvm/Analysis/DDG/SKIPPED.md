# Skipped while importing llvm/test/Analysis/DDG (llvmorg-23.1.5)

0 of 5 files imported. Regenerate with `./harness/run import-llvm Analysis/DDG`.

- `basic-a.ll` @analysis `'-passes=print<ddg>'`: nondeterministic output
- `basic-a.ll`: no working RUN lines
- `basic-b.ll` @analysis `'-passes=print<ddg>'`: nondeterministic output
- `basic-b.ll`: no working RUN lines
- `basic-loopnest.ll`: XFAIL in LLVM
- `print-dot-ddg.ll` RUN `opt -aa-pipeline=basic-aa -passes=dot-ddg -dot-ddg-filename-prefix=%t < %s 2>&1 > /dev/null`: writes .dot files
- `print-dot-ddg.ll` RUN `FileCheck %s -input-file=%t.foo.for.body.dot`: not an opt invocation
- `print-dot-ddg.ll` RUN `opt -aa-pipeline=basic-aa -passes=dot-ddg -dot-ddg-filename-prefix=%t -dot-ddg-only < %s 2>&1 > /dev/null`: writes .dot files
- `print-dot-ddg.ll` RUN `FileCheck %s -input-file=%t.foo.for.body.dot -check-prefix=CHECK-ONLY`: not an opt invocation
- `root-node.ll` @analysis `'-passes=print<ddg>'`: nondeterministic output
- `root-node.ll`: no working RUN lines
