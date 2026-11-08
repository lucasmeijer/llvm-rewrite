; @origin: llvm/test/Analysis/CallGraph/do-nothing-intrinsic.ll (llvmorg-23.1.5)
; @opt: '-passes=require<callgraph>'
; RUN: opt < %s -passes='require<callgraph>'
; PR13903

define void @main() personality i8 0 {
  invoke void @llvm.donothing()
          to label %ret unwind label %unw
unw:
  %tmp = landingpad i8 cleanup
  br label %ret
ret:
  ret void
}
declare void @llvm.donothing() nounwind readnone
