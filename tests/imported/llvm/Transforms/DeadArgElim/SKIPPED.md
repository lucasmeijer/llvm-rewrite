# Skipped while importing llvm/test/Transforms/DeadArgElim (llvmorg-23.1.5)

39 of 43 files imported. Regenerate with `./harness/run import-llvm Transforms/DeadArgElim`.

- `2007-12-20-ParamAttrs.ll` RUN `opt < %s -passes=deadargelim -S -pass-remarks-output=%t | FileCheck %s`: uses lit substitution -pass-remarks-output=%t
- `2007-12-20-ParamAttrs.ll` RUN `cat %t | FileCheck -check-prefix=REMARK %s`: not an opt invocation
- `2008-06-23-DeadAfterLive.ll` RUN `opt < %s -passes='deadargelim,function(dce)' -S > %t`: redirects or chains commands
- `2008-06-23-DeadAfterLive.ll` RUN `cat %t | grep 123`: not an opt invocation
- `canon.ll` RUN `opt < %s -passes=deadargelim -S > %t`: redirects or chains commands
- `canon.ll` RUN `cat %t | grep "define internal void @test"`: not an opt invocation
- `canon.ll` RUN `cat %t | grep "define internal i32 @test2"`: not an opt invocation
- `deadretval2.ll` RUN `opt < %s -passes='deadargelim,function(dce)' -S > %t`: redirects or chains commands
- `deadretval2.ll` RUN `cat %t | not grep DEAD`: not an opt invocation
- `deadretval2.ll` RUN `cat %t | grep LIVE | count 4`: not an opt invocation
