# Skipped while importing llvm/test/Analysis/IR2Vec (llvmorg-23.1.5)

5 of 7 files imported. Regenerate with `./harness/run import-llvm Analysis/IR2Vec`.

- `basic-vocab.ll` RUN `not opt -passes='print<ir2vec>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/incorrect_vocab1.json %s 2>&1 | FileCheck %s -check-prefix=INCORRECT-VOCAB1-CHECK`: not an opt invocation
- `basic-vocab.ll` RUN `not opt -passes='print<ir2vec>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/incorrect_vocab2.json %s 2>&1 | FileCheck %s -check-prefix=INCORRECT-VOCAB2-CHECK`: not an opt invocation
- `basic-vocab.ll` RUN `not opt -passes='print<ir2vec>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/incorrect_vocab3.json %s 2>&1 | FileCheck %s -check-prefix=INCORRECT-VOCAB3-CHECK`: not an opt invocation
- `basic-vocab.ll` RUN `not opt -passes='print<ir2vec>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/incorrect_vocab4.json %s 2>&1 | FileCheck %s -check-prefix=INCORRECT-VOCAB4-CHECK`: not an opt invocation
- `vocab-test.ll` RUN `opt -passes='print<ir2vec-vocab>' -S -o /dev/null -ir2vec-vocab-path=%S/Inputs/dummy_2D_vocab.json %s 2> %t1.log`: redirects or chains commands
- `vocab-test.ll` RUN `diff %S/Inputs/reference_default_vocab_print.txt %t1.log`: not an opt invocation
- `vocab-test.ll` RUN `opt -passes='print<ir2vec-vocab>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/dummy_2D_vocab.json -ir2vec-opc-weight=0.5 -ir2vec-type-weight=0.5 -ir2vec-arg-weight=0.5 %s 2> %t2.log`: redirects or chains commands
- `vocab-test.ll` RUN `diff %S/Inputs/reference_wtd1_vocab_print.txt %t2.log`: not an opt invocation
- `vocab-test.ll` RUN `opt -passes='print<ir2vec-vocab>' -o /dev/null -ir2vec-vocab-path=%S/Inputs/dummy_2D_vocab.json -ir2vec-opc-weight=0.1 -ir2vec-type-weight=0 -ir2vec-arg-weight=0 %s 2> %t3.log`: redirects or chains commands
- `vocab-test.ll` RUN `diff %S/Inputs/reference_wtd2_vocab_print.txt %t3.log`: not an opt invocation
