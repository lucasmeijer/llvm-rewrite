; @origin: llvm/test/Transforms/PGOProfile/infinite_loop_gen.ll (llvmorg-23.1.5)
; @opt: -passes=pgo-instr-gen
; RUN: opt < %s -passes=pgo-instr-gen -S | FileCheck %s

define void @foo() {
entry:
  br label %while.body
  ; CHECK: llvm.instrprof.increment

    while.body:                                       ; preds = %entry, %while.body
    ; CHECK: llvm.instrprof.increment
        call void (...) @bar() #2
    br label %while.body
}

declare void @bar(...)

attributes #0 = { nounwind }

