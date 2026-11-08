; ADCE removes the dead branches in %a and %d; the post-dominator and dominator trees are updated
; incrementally (DomTreeUpdater, eager) instead of being recomputed.
; @analysis: -passes='require<domtree>,adce,print<domtree>,print<postdomtree>'
declare void @g(i32)

define void @f(i1 %c0, i1 %c1, i32 %x) {
entry:
  br i1 %c0, label %a, label %d

a:
  br i1 %c1, label %b, label %c

b:
  br label %join

c:
  br label %join

d:
  switch i32 %x, label %e [ i32 0, label %join
                            i32 1, label %f ]

e:
  br label %f

f:
  call void @g(i32 1)
  br label %join

join:
  call void @g(i32 2)
  ret void
}
