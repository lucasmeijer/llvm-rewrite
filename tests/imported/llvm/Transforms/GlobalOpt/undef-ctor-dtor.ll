; @origin: llvm/test/Transforms/GlobalOpt/undef-ctor-dtor.ll (llvmorg-23.1.5)
; @opt: -passes=globalopt
; RUN: opt -S -passes=globalopt < %s | FileCheck %s

; Gracefully handle undef global_ctors/global_dtors

; CHECK: @llvm.global_ctors = appending global [0 x { i32, ptr, ptr }] undef
; CHECK: @llvm.global_dtors = appending global [0 x { i32, ptr, ptr }] undef

@llvm.global_ctors = appending global [0 x { i32, ptr, ptr }] undef
@llvm.global_dtors = appending global [0 x { i32, ptr, ptr }] undef
