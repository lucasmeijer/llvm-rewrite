; @origin: llvm/test/Transforms/Inline/2003-09-22-PHINodeInlineFail.ll (llvmorg-23.1.5)
; @opt: -passes=inline
; RUN: opt < %s -passes=inline -disable-output

define i32 @main() personality ptr @__gxx_personality_v0 {
entry:
        invoke void @__main( )
                        to label %LongJmpBlkPost unwind label %LongJmpBlkPre

LongJmpBlkPost:
        ret i32 0

LongJmpBlkPre:
        %i.3 = phi i32 [ 0, %entry ]
        %exn = landingpad {ptr, i32}
                 cleanup
        ret i32 0
}

define void @__main() {
        ret void
}

declare i32 @__gxx_personality_v0(...)
