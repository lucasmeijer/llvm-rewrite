# Skipped while importing llvm/test/Transforms/BlockExtractor (llvmorg-23.1.5)

0 of 5 files imported. Regenerate with `./harness/run import-llvm Transforms/BlockExtractor`.

- `extract-blocks-with-groups.ll` RUN `echo 'foo if;then;else' > %t`: not an opt invocation
- `extract-blocks-with-groups.ll` RUN `echo 'foo end' >> %t`: not an opt invocation
- `extract-blocks-with-groups.ll` RUN `echo 'bar bb14;bb20' >> %t`: not an opt invocation
- `extract-blocks-with-groups.ll` RUN `opt -S -passes=extract-blocks -extract-blocks-file=%t %s | FileCheck %s`: uses lit substitution -extract-blocks-file=%t
- `extract-blocks.ll` RUN `echo 'foo bb9' > %t`: not an opt invocation
- `extract-blocks.ll` RUN `echo 'foo bb20' >> %t`: not an opt invocation
- `extract-blocks.ll` RUN `opt -S -passes=extract-blocks -extract-blocks-file=%t %s | FileCheck %s --check-prefix=CHECK-NO-ERASE`: uses lit substitution -extract-blocks-file=%t
- `extract-blocks.ll` RUN `opt -S -passes=extract-blocks -extract-blocks-file=%t -extract-blocks-erase-funcs %s | FileCheck %s --check-prefix=CHECK-ERASE`: uses lit substitution -extract-blocks-file=%t
- `invalid-block.ll` RUN `echo 'bar invalidbb' > %t`: not an opt invocation
- `invalid-block.ll` RUN `not opt -S -passes=extract-blocks -extract-blocks-file=%t %s 2>&1 | FileCheck %s`: not an opt invocation
- `invalid-function.ll` RUN `echo 'foo bb' > %t`: not an opt invocation
- `invalid-function.ll` RUN `not opt -S -passes=extract-blocks -extract-blocks-file=%t %s 2>&1 | FileCheck %s`: not an opt invocation
- `invalid-line.ll` RUN `echo 'foo' > %t`: not an opt invocation
- `invalid-line.ll` RUN `not opt -S -passes=extract-blocks -extract-blocks-file=%t %s 2>&1 | FileCheck %s`: not an opt invocation
