target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S = type { i32, i64 }
%struct.T = type { i8, ptr }
%struct.Opaque = type opaque
%struct.Rec = type { ptr, i32 }

@gs = global %struct.S { i32 1, i64 2 }
@gt = global %struct.T zeroinitializer
@go = external global %struct.Opaque

define i64 @use_s(ptr %p) {
  %f = getelementptr %struct.S, ptr %p, i32 0, i32 1
  %v = load i64, ptr %f
  ret i64 %v
}

declare void @take_t(%struct.T)
declare %struct.Rec @make_rec()
