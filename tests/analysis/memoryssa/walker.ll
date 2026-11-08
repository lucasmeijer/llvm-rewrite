; The MemorySSA walker: the clobbering access of each load, which skips stores to provably different memory.
; @analysis: -aa-pipeline=basic-aa -passes='print<memoryssa-walker>'
define i32 @f(i1 %c) {
entry:
  %x = alloca i32
  %y = alloca i32
  store i32 1, ptr %x
  store i32 2, ptr %y
  br i1 %c, label %then, label %join

then:
  store i32 3, ptr %y
  br label %join

join:
  %vx = load i32, ptr %x
  %vy = load i32, ptr %y
  %r = add i32 %vx, %vy
  ret i32 %r
}
