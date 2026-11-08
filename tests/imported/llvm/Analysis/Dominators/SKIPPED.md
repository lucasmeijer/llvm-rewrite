# Skipped while importing llvm/test/Analysis/Dominators (llvmorg-23.1.5)

6 of 7 files imported. Regenerate with `./harness/run import-llvm Analysis/Dominators`.

- `print-dot-dom.ll` RUN `rm -rf %t`: not an opt invocation
- `print-dot-dom.ll` RUN `mkdir %t`: not an opt invocation
- `print-dot-dom.ll` RUN `cd %t`: not an opt invocation
- `print-dot-dom.ll` RUN `opt %s -passes=dot-dom -disable-output`: writes .dot files
- `print-dot-dom.ll` RUN `FileCheck %s -input-file=dom.test1.dot -check-prefix=TEST1`: not an opt invocation
- `print-dot-dom.ll` RUN `FileCheck %s -input-file=dom.test2.dot -check-prefix=TEST2`: not an opt invocation
