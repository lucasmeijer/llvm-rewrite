target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@g = global i32 1
@ga = alias i32, ptr @g
@wa = weak alias i32, ptr @g

define i32 @f() {
  ret i32 1
}

@fa = alias i32 (), ptr @f
@ifn = ifunc i32 (), ptr @resolver

define internal ptr @resolver() {
  ret ptr @f
}

declare i32 @fb_alias()
