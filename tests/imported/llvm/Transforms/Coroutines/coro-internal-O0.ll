; @origin: llvm/test/Transforms/Coroutines/coro-internal-O0.ll (llvmorg-23.1.5)
; @opt: '-passes=default<O0>'
; RUN: opt -passes='default<O0>' -S < %s | FileCheck %s

; CHECK-NOT: call .*llvm.coro.size

declare i64 @llvm.coro.size.i64()
define internal i64 @f() {
  %a = call i64 @llvm.coro.size.i64()
  ret i64 %a
}

