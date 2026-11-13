target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@w = weak global i32 1
@s = weak global i32 2
@c = common global i32 0, align 4
@c2 = common global [2 x i64] zeroinitializer, align 8
@ae = available_externally global i32 5
@ext = external global i32
@ew = extern_weak global i32
@lo = linkonce global i32 4
@aligned = global i32 0, align 4

define weak i32 @fw() {
  ret i32 1
}

define linkonce_odr i32 @flo() {
  ret i32 10
}

define available_externally i32 @fae() {
  ret i32 100
}

declare i32 @fdecl(i32)

define i32 @user() {
  %a = load i32, ptr @w
  %b = load i32, ptr @ext
  %c = call i32 @fw()
  %d = call i32 @flo()
  %e = call i32 @fae()
  %f = call i32 @fdecl(i32 %a)
  %g = load i32, ptr @ew
  %s1 = add i32 %a, %b
  %s2 = add i32 %s1, %c
  %s3 = add i32 %s2, %d
  %s4 = add i32 %s3, %e
  %s5 = add i32 %s4, %f
  %s6 = add i32 %s5, %g
  ret i32 %s6
}
