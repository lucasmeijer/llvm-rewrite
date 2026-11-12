; Function analyses persist across function adaptors (FunctionAnalysisManager): early-cse<memssa> keeps the
; MemorySSA of each function up to date, and print<memoryssa> in the next adaptor prints the cached one (access
; ids with the gaps left by removed accesses), not a fresh one. Two functions, so @f's result is cached while
; @g's is built.
; @analysis: -passes='function(early-cse<memssa>),function(print<memoryssa>)'

define i32 @f(ptr %p, ptr %q) {
entry:
  %a = load i32, ptr %p
  store i32 %a, ptr %p
  store i32 1, ptr %q
  store i32 2, ptr %q
  %b = load i32, ptr %q
  %c = load i32, ptr %p
  store i32 3, ptr %p
  %s = add i32 %b, %c
  ret i32 %s
}

define i32 @g(ptr %p, i1 %c) {
entry:
  %x = load i32, ptr %p
  br i1 %c, label %then, label %join

then:
  store i32 %x, ptr %p
  %y = load i32, ptr %p
  br label %join

join:
  %r = phi i32 [ %x, %entry ], [ %y, %then ]
  %z = load i32, ptr %p
  %t = add i32 %r, %z
  ret i32 %t
}
