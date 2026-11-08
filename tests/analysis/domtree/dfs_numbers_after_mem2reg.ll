; mem2reg's IDF computation (IDFCalculatorBase::calculate) calls DominatorTree::updateDFSNumbers, so the
; dominator tree printed after mem2reg shows valid DFS numbers.
; @analysis: -passes='mem2reg,print<domtree>'
define i32 @f(i1 %c) {
entry:
  %x = alloca i32
  store i32 0, ptr %x
  br i1 %c, label %a, label %b

a:
  store i32 1, ptr %x
  br label %j

b:
  br label %j

j:
  %v = load i32, ptr %x
  ret i32 %v
}
