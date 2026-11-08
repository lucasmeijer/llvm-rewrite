; @origin: llvm/test/Transforms/InstCombine/2009-06-11-StoreAddrSpace.ll (llvmorg-23.1.5)
; @opt: -passes=instcombine
; RUN: opt < %s -passes=instcombine -S | grep "store i32 0,"
; PR4366

define void @a() {
  store i32 0, ptr addrspace(1) null
  ret void
}
