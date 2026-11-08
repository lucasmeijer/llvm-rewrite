; @origin: llvm/test/Transforms/GlobalDCE/2002-07-17-ConstantRef.ll (llvmorg-23.1.5)
; @opt: -passes=globaldce
; RUN: opt < %s -passes=globaldce
;

@X = global ptr @func              ; <ptr> [#uses=0]

; Not dead, can be reachable via X
define internal void @func() {
        ret void
}

define void @main() {
        ret void
}
