target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@h = global i32 2
@wa = alias i32, ptr @h

define i32 @fb() {
  %a = load i32, ptr @ga
  %b = call i32 @fa()
  %c = call i32 @ifn()
  %s = add i32 %a, %b
  %t = add i32 %s, %c
  ret i32 %t
}

@fb_alias = alias i32 (), ptr @fb
@ga = external global i32
declare i32 @fa()
declare i32 @ifn()
