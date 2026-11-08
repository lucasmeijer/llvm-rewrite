; @origin: llvm/test/Transforms/GlobalDCE/2002-07-17-CastRef.ll (llvmorg-23.1.5)
; @opt: -passes=globaldce
; RUN: opt < %s -passes=globaldce
;
define internal void @func() {
        ret void
}

define void @main() {
        %X = addrspacecast ptr @func to ptr addrspace(1)             ; <i32*> [#uses=0]
        ret void
}

