; @origin: llvm/test/Instrumentation/ThreadSanitizer/personality.ll (llvmorg-23.1.5)
; @opt: --mtriple=x86_64-unknown-linux-gnu -passes=tsan
; @opt: --mtriple=x86_64-scei-ps4 -passes=tsan
; @opt: --mtriple=x86_64-sie-ps5 -passes=tsan
; RUN: opt --mtriple=x86_64-unknown-linux-gnu < %s -passes=tsan -S | FileCheck %s --check-prefix=GCC
; RUN: opt --mtriple=x86_64-scei-ps4 < %s -passes=tsan -S | FileCheck %s --check-prefix=GCC
; RUN: opt --mtriple=x86_64-sie-ps5  < %s -passes=tsan -S | FileCheck %s --check-prefix=GXX

declare void @foo()

define i32 @func1() sanitize_thread {
  call void @foo()
  ret i32 0
  ; GCC: __gcc_personality_v0
  ; GXX: __gxx_personality_v0
}
