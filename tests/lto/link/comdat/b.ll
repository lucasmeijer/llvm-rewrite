target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

$inl = comdat any
$big = comdat largest
$same = comdat exactmatch

@big = global [8 x i32] zeroinitializer, comdat
@same = linkonce_odr global i32 3, comdat

define linkonce_odr i32 @inl(i32 %x) comdat {
  %r = add i32 %x, 2
  ret i32 %r
}

define i32 @call_b(i32 %x) {
  %r = call i32 @inl(i32 %x)
  ret i32 %r
}
