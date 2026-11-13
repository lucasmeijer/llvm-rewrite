target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S = type { i32, i64 }
%struct.T = type { i16, ptr }
%struct.Opaque = type { i32 }
%struct.Rec = type { ptr, i32 }
%struct.Only = type { double }

@go = global %struct.Opaque { i32 7 }
@gonly = global %struct.Only zeroinitializer

define void @take_t(%struct.T %t) {
  ret void
}

define %struct.Rec @make_rec() {
  ret %struct.Rec zeroinitializer
}

define i32 @use_s2(ptr %p) {
  %f = getelementptr %struct.S, ptr %p, i32 0, i32 0
  %v = load i32, ptr %f
  ret i32 %v
}
