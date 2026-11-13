; foldPHIArgOpIntoPHI must not merge compares with different predicates (Instruction::isSameOperationAs compares
; the predicate): phi [icmp ne %x, 0], [icmp eq %z, 0] stays.
; @opt: -passes=instcombine
define i1 @f(i32 %x, i32 %z, i1 %c) {
entry:
  %c.1 = icmp ne i32 %x, 0
  br i1 %c, label %then, label %exit
then:
  %c.4 = icmp eq i32 %z, 0
  br label %exit
exit:
  %res = phi i1 [ %c.1, %entry ], [ %c.4, %then ]
  ret i1 %res
}
define i1 @g(float %x, float %z, i1 %c) {
entry:
  %c.1 = fcmp olt float %x, 0.0
  br i1 %c, label %then, label %exit
then:
  %c.4 = fcmp ogt float %z, 0.0
  br label %exit
exit:
  %res = phi i1 [ %c.1, %entry ], [ %c.4, %then ]
  ret i1 %res
}
