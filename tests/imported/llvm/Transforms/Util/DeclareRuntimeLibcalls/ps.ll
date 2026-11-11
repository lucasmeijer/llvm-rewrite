; @origin: llvm/test/Transforms/Util/DeclareRuntimeLibcalls/ps.ll (llvmorg-23.1.5)
; @opt: -passes=declare-runtime-libcalls -mtriple=x86_64-scei-ps4
; @opt: -passes=declare-runtime-libcalls -mtriple=x86_64-scei-ps5
; RUN: opt -S -passes=declare-runtime-libcalls -mtriple=x86_64-scei-ps4 < %s | FileCheck %s
; RUN: opt -S -passes=declare-runtime-libcalls -mtriple=x86_64-scei-ps5 < %s | FileCheck %s

; CHECK-NOT: __memcpy_chk
; CHECK-NOT: __memset_chk
; CHECK-NOT: __memmove_chk
