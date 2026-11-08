; MemorySSA: MemoryDefs, MemoryUses and MemoryPhis for stores/loads in a diamond inside a loop, plus a call
; and a readonly call; built with BasicAA. verify<memoryssa> afterwards.
; @analysis: -aa-pipeline=basic-aa -passes='print<memoryssa>,verify<memoryssa>'
declare void @clobber(ptr)
declare i32 @peek(ptr) readonly

define i32 @f(ptr noalias %a, ptr noalias %b, i32 %n) {
entry:
  %local = alloca i32
  store i32 0, ptr %local
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %latch ]
  %va = load i32, ptr %a
  %odd = and i32 %i, 1
  %c = icmp eq i32 %odd, 0
  br i1 %c, label %even, label %oddb

even:
  store i32 %i, ptr %a
  br label %latch

oddb:
  store i32 %va, ptr %b
  call void @clobber(ptr %b)
  br label %latch

latch:
  %vb = load i32, ptr %b
  %pk = call i32 @peek(ptr %a)
  %i.next = add i32 %i, 1
  %cl = icmp slt i32 %i.next, %n
  br i1 %cl, label %loop, label %exit

exit:
  %vl = load i32, ptr %local
  %r = add i32 %vl, %vb
  ret i32 %r
}
