; @origin: llvm/test/Transforms/PGOProfile/global_variables_only.ll (llvmorg-23.1.5)
; @opt: -passes=pgo-instr-gen
; RUN: opt < %s -passes=pgo-instr-gen -S | FileCheck %s --check-prefix=GEN-COMDAT

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; GEN-COMDAT: $__llvm_profile_raw_version = comdat any
; GEN-COMDAT: @__llvm_profile_raw_version = hidden constant i64 {{[0-9]+}}, comdat

@var = internal unnamed_addr global [35 x ptr] zeroinitializer, align 16
