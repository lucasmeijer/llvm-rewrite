; @origin: llvm/test/Transforms/GlobalDCE/2009-02-17-AliasUsesAliasee.ll (llvmorg-23.1.5)
; @opt: -passes=globaldce
; RUN: opt < %s -passes=globaldce

@A = internal alias void (), ptr @F
define internal void @F() { ret void }
