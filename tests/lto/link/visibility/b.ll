target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@v1 = external global i32
@v2 = protected global i32 2
@v3 = external hidden global i32
@u1 = external constant i32
@u2 = external unnamed_addr constant i32
@d = external global i32

define void @pf() {
  ret void
}
declare void @hf()
