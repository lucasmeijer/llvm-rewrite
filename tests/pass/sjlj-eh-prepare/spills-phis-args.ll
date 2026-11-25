; SjLjEHPrepare: incoming arguments become selects, values live into a landing pad are spilled (volatile reloads),
; landing pad phis are demoted, extractvalues of the landingpad read the function context, allocas and
; stackrestore outside the entry block save the stack pointer, invokes of llvm.donothing become branches.
; @opt: -passes=sjlj-eh-prepare
declare void @may_throw(i32)
declare i32 @get()
declare i32 @__gxx_personality_sj0(...)
declare void @llvm.donothing()
declare void @llvm.stackrestore.p0(ptr)
declare ptr @llvm.stacksave.p0()
@ti = external constant ptr

define i32 @f(i32 %a, ptr %p, i1 %c) personality ptr @__gxx_personality_sj0 {
entry:
  %local = alloca i32
  %v = call i32 @get()
  %w = add i32 %v, %a
  invoke void @llvm.donothing() to label %d unwind label %lpad
d:
  br i1 %c, label %t, label %e
t:
  %x = add i32 %w, 1
  invoke void @may_throw(i32 %x) to label %join unwind label %lpad
e:
  %y = mul i32 %w, 3
  %dyn = alloca i32, i32 %y
  store i32 %y, ptr %dyn
  invoke void @may_throw(i32 %y) to label %join unwind label %lpad2
join:
  %r = phi i32 [ %x, %t ], [ %y, %e ]
  ret i32 %r
lpad:
  %ph = phi i32 [ %w, %entry ], [ %x, %t ]
  %lp = landingpad { ptr, i32 } cleanup catch ptr @ti
  %exn = extractvalue { ptr, i32 } %lp, 0
  %sel = extractvalue { ptr, i32 } %lp, 1
  store i32 %sel, ptr %p
  %sum = add i32 %ph, %w
  ret i32 %sum
lpad2:
  %lp2 = landingpad { ptr, i32 } cleanup
  %ss = call ptr @llvm.stacksave.p0()
  call void @llvm.stackrestore.p0(ptr %ss)
  resume { ptr, i32 } %lp2
}

define void @no_invokes() {
  call void @may_throw(i32 0)
  ret void
}
