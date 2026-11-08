; BasicAA via aa-eval: allocas vs arguments, noalias arguments, constant and variable GEP offsets, a call's
; mod/ref behaviour (readonly, argmemonly, unknown).
; @analysis: -aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare i32 @reads(ptr) readonly
declare void @writes_arg(ptr) argmemonly
declare void @unknown(ptr)

define void @f(ptr noalias %na, ptr %p, ptr %q, i64 %k) {
  %local = alloca [8 x i32]
  %l0 = getelementptr inbounds [8 x i32], ptr %local, i64 0, i64 0
  %l1 = getelementptr inbounds [8 x i32], ptr %local, i64 0, i64 1
  %lk = getelementptr inbounds [8 x i32], ptr %local, i64 0, i64 %k
  %p4 = getelementptr inbounds i8, ptr %p, i64 4
  %pk = getelementptr inbounds i32, ptr %p, i64 %k
  store i32 0, ptr %l0
  store i32 1, ptr %l1
  store i32 2, ptr %lk
  store i32 3, ptr %p
  store i32 4, ptr %p4
  store i32 5, ptr %pk
  store i32 6, ptr %q
  store i32 7, ptr %na
  %r = call i32 @reads(ptr %p)
  call void @writes_arg(ptr %l0)
  call void @unknown(ptr %q)
  ret void
}
