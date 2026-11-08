; @origin: llvm/test/Transforms/ConstantMerge/2011-01-15-EitherOrder.ll (llvmorg-23.1.5)
; @opt: -passes=constmerge
; RUN: opt -passes=constmerge -S < %s | FileCheck %s
; PR8978

declare i32 @zed(ptr, ptr)

%struct.foobar = type { i32 }
; CHECK: bar.d
@bar.d =  unnamed_addr constant %struct.foobar zeroinitializer, align 4
; CHECK-NOT: foo.d
@foo.d = internal constant %struct.foobar zeroinitializer, align 4
define i32 @main() nounwind ssp {
entry:
; CHECK: bar.d
  %call2 = tail call i32 @zed(ptr @foo.d, ptr @bar.d)
nounwind
  ret i32 0
}

