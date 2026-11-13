target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@counter = internal global i32 5
@.str = private unnamed_addr constant [4 x i8] c"xyz\00"
@helper.1 = global i32 1

define internal i32 @helper(i32 %x) {
  %r = mul i32 %x, 2
  ret i32 %r
}

define i32 @b(i32 %x) {
  %c = load i32, ptr @counter
  %r = call i32 @helper(i32 %c)
  %p = load i8, ptr @.str
  %e = zext i8 %p to i32
  %s = add i32 %r, %e
  ret i32 %s
}
