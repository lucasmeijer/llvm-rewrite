# Skipped while importing llvm/test/Transforms/ArgumentPromotion (llvmorg-23.1.5)

55 of 60 files imported. Regenerate with `./harness/run import-llvm Transforms/ArgumentPromotion`.

- `2008-02-01-ReturnAttrs.ll` RUN `opt < %s -passes=argpromotion -S -pass-remarks-output=%t | FileCheck %s`: uses lit substitution -pass-remarks-output=%t
- `2008-02-01-ReturnAttrs.ll` RUN `cat %t | FileCheck -check-prefix=REMARK %s`: not an opt invocation
- `argpromotion.ll`: in a BPF target directory
- `thiscall.ll`: target triple i386-pc-windows-msvc19.11.0
- `aliasing-and-non-aliasing-loads-with-clobber.ll` RUN `opt -p argpromotion -S %s | FileCheck %s`: no -passes / -O pipeline
- `invalidation.ll` RUN `opt < %s -passes='function(print<demanded-bits>),cgscc(argpromotion,function(print<demanded-bits>))' -S | FileCheck %s`: analysis printer (stderr output) not supported yet
- `pr27568.ll` RUN `opt -S -passes=debugify -o /dev/null < %s`: writes to a file
