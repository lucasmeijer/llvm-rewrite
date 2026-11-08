@a = global i32 1
@b = internal global i32 2, align 4
@c = private unnamed_addr constant [6 x i8] c"hello\00", align 1
@d = external global i64
@e = weak global ptr null
@f = linkonce_odr dso_local constant i8 3
@g = common global i32 0, align 4
@h = thread_local global i32 7
@i = hidden global i32 0, section ".mysec"
@j = appending global [1 x ptr] [ptr @fn]
@k = available_externally global i32 9
@l = local_unnamed_addr global ptr @a
@m = global ptr getelementptr inbounds ([6 x i8], ptr @c, i64 0, i64 2)
@n = global i64 ptrtoint (ptr @a to i64)

@alias = alias i32, ptr @a
@ifunc = ifunc void (), ptr @resolver

$cd = comdat any
@in_comdat = linkonce_odr global i32 0, comdat($cd)

define internal void @fn() {
  ret void
}

define ptr @resolver() {
  ret ptr @fn
}

define weak_odr hidden void @w() unnamed_addr {
  ret void
}
