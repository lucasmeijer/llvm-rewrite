target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@v1 = hidden global i32 1
@v2 = external global i32
@v3 = global i32 3, align 4
@u1 = unnamed_addr constant i32 4
@u2 = local_unnamed_addr constant i32 5
@d = dso_local global i32 6

declare protected void @pf()
define hidden void @hf() {
  ret void
}
define void @caller() {
  call void @pf()
  call void @hf()
  ret void
}
