; LazyValueInfo's cached lattice values after jump-threading queried them: constant ranges from branch conditions,
; through a phi, and overdefined values. (Needs jump-threading's queries to match, so it also tests JumpThreading.)
; @analysis: -passes='jump-threading,print<lazy-value-info>'
declare void @use(i32)

define i32 @f(i32 %a, i32 %b) {
entry:
  %lo = icmp ult i32 %a, 100
  br i1 %lo, label %small, label %big

small:
  %ab = add nuw i32 %a, 10
  br label %join

big:
  call void @use(i32 %b)
  br label %join

join:
  %p = phi i32 [ %ab, %small ], [ 5, %big ]
  %c = icmp ugt i32 %p, 200
  br i1 %c, label %never, label %always

never:
  ret i32 0

always:
  ret i32 %p
}
