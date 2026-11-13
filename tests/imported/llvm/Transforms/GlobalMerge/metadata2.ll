; @origin: llvm/test/Transforms/GlobalMerge/metadata2.ll (llvmorg-23.1.5)
; @opt: -passes=global-merge -global-merge-max-offset=100
; @opt: '-passes=global-merge<max-offset=100>'
; RUN: opt -global-merge -global-merge-max-offset=100 -S -o - %s | FileCheck %s
; RUN: opt -passes='global-merge<max-offset=100>' -S -o - %s | FileCheck %s

target datalayout = "e-p:64:64"
target triple = "x86_64-unknown-linux-gnu"
; CHECK-NOT: @_MergedGlobals

@a = internal global i32 1
@b = internal global i32 2, !foo !{}

define void @use1() {
  %x = load i32, ptr @a
  %y = load i32, ptr @b
  ret void
}
