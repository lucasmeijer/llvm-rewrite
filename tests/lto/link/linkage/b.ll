target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@w = global i32 10
@s = weak global i32 20
@c = common global i64 0, align 8
@c2 = common global [1 x i64] zeroinitializer, align 16
@ae = global i32 5
@ext = global i32 3
@lo = linkonce global i32 4
@aligned = external global i32, align 16

define i32 @fw() {
  ret i32 2
}

define weak_odr i32 @flo() {
  ret i32 10
}

define i32 @fae() {
  ret i32 100
}

define i32 @fdecl(i32 %x) {
  ret i32 %x
}
