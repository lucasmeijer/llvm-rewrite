# Skipped while importing llvm/test/Transforms/LoopTransformWarning (llvmorg-23.1.5)

1 of 7 files imported. Regenerate with `./harness/run import-llvm Transforms/LoopTransformWarning`.

- `distribution-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-missed=transform-warning -pass-remarks-analysis=transform-warning 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `distribution-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-output=%t.yaml`: uses lit substitution -pass-remarks-output=%t.yaml
- `distribution-remarks-missed.ll` RUN `cat %t.yaml | FileCheck -check-prefix=YAML %s`: not an opt invocation
- `optnone.ll` RUN `opt -passes=transform-warning -disable-output -pass-remarks-missed=transform-warning -pass-remarks-analysis=transform-warning < %s 2>&1 | FileCheck -allow-empty %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `unrollandjam-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-missed=transform-warning -pass-remarks-analysis=transform-warning 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `unrollandjam-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-output=%t.yaml`: uses lit substitution -pass-remarks-output=%t.yaml
- `unrollandjam-remarks-missed.ll` RUN `cat %t.yaml | FileCheck -check-prefix=YAML %s`: not an opt invocation
- `unrolling-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-missed=transform-warning -pass-remarks-analysis=transform-warning 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `unrolling-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-output=%t.yaml`: uses lit substitution -pass-remarks-output=%t.yaml
- `unrolling-remarks-missed.ll` RUN `cat %t.yaml | FileCheck -check-prefix=YAML %s`: not an opt invocation
- `vectorization-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-missed=transform-warning -pass-remarks-analysis=transform-warning 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `vectorization-remarks-missed.ll` RUN `opt < %s -passes=transform-warning -disable-output -pass-remarks-output=%t.yaml`: uses lit substitution -pass-remarks-output=%t.yaml
- `vectorization-remarks-missed.ll` RUN `cat %t.yaml | FileCheck -check-prefix=YAML %s`: not an opt invocation
- `vectorizer-loop-kind-unroll-warning.ll` RUN `opt < %s -passes='loop-vectorize,loop-unroll,transform-warning' -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization -epilogue-vectorization-force-VF=4 -disable-output -pass-remarks-missed=transform-warning 2>&1 | FileCheck %s`: diagnostic output flag -pass-remarks-missed=transform-warning
- `vectorizer-loop-kind-unroll-warning.ll` RUN `opt < %s -passes='loop-vectorize,loop-unroll,transform-warning' -force-vector-width=4 -force-vector-interleave=1 -enable-epilogue-vectorization -epilogue-vectorization-force-VF=4 -disable-output -pass-remarks-output=%t.yaml 2>&1`: uses lit substitution -pass-remarks-output=%t.yaml
- `vectorizer-loop-kind-unroll-warning.ll` RUN `FileCheck --input-file=%t.yaml %s --check-prefix=YAML`: not an opt invocation
