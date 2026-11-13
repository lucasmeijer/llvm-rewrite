# Skipped while importing llvm/test/Transforms/CodeExtractor (llvmorg-23.1.5)

53 of 56 files imported. Regenerate with `./harness/run import-llvm Transforms/CodeExtractor`.

- `PartialInlineNoInline.ll` RUN `opt < %s -passes=partial-inliner -S -stats -pass-remarks=partial-inlining 2>&1 | FileCheck %s`: diagnostic output flag -stats
- `PartialInlineORECrash.ll`: target triple powerpc64le-unknown-linux-gnu
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner -pass-remarks=partial-inlining  -disable-output < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner  -pass-remarks=partial-inlining -disable-output < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner -pass-remarks=partial-inlining  -disable-output -max-partial-inlining=1 < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner  -pass-remarks=partial-inlining -disable-output -max-partial-inlining=1 < %s 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner -pass-remarks=partial-inlining  -disable-partial-inlining < %s 2>&1 | FileCheck --check-prefix=LIMIT %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner  -pass-remarks=partial-inlining  --disable-partial-inlining < %s 2>&1 | FileCheck  --check-prefix=LIMIT %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner -pass-remarks=partial-inlining   -max-partial-inlining=0 < %s 2>&1 | FileCheck --check-prefix=LIMIT  %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner  -pass-remarks=partial-inlining  -max-partial-inlining=0 < %s 2>&1 | FileCheck --check-prefix=LIMIT  %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner -pass-remarks=partial-inlining   -inline-threshold=0 < %s 2>&1 | FileCheck --check-prefix=LIMIT  %s`: diagnostic output flag -pass-remarks=partial-inlining
- `PartialInlineOptRemark.ll` RUN `opt -S -passes=partial-inliner  -pass-remarks=partial-inlining  -inline-threshold=0 < %s 2>&1 | FileCheck --check-prefix=LIMIT  %s`: diagnostic output flag -pass-remarks=partial-inlining
