; LowerEmuTLSPass: every thread_local global gets __emutls_v.<name> (a new unnamed struct type each), and
; __emutls_t.<name> for a nonzero initializer; comdats and linkage are copied; an existing __emutls_v. name is skipped.
; @opt: -passes=lower-emutls
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"
$c = comdat any
@a = thread_local global i32 0
@b = internal thread_local global i64 42, align 16
@c = linkonce_odr hidden thread_local global [2 x i32] [i32 1, i32 2], comdat
@d = external thread_local global i8
@e = dso_local thread_local(initialexec) global { i32, i8 } zeroinitializer
@__emutls_v.f = global i8 0
@f = thread_local global i32 5
define ptr @use() { ret ptr @a }
