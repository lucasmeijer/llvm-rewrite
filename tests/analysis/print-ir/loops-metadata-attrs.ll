; PrintModulePass / PrintFunctionPass / PrintLoopPass (`print` at each level, printing to stderr) and
; HelloWorldPass: function printing initializes all metadata (Value::print of a Function) but numbers only the
; function attributes and the printed function's call-site attribute groups; loop printing shows the preheader,
; the loop blocks and the exit blocks.
; @analysis: -passes=print
; @analysis: '-passes=function(print)'
; @analysis: '-passes=function(loop(print))'
; @analysis: '-passes=function(loop(loop-rotate,print))'
; @analysis: -passes=helloworld
; @analysis: '-passes=cgscc(print)'
target triple = "x86_64-unknown-linux-gnu"

@g = global i32 0, !dbg !10

declare i32 @strcmp(ptr, ptr) #0
declare ptr @strcpy(ptr, ptr) #1

define i32 @first(ptr %a, ptr %b) #2 !dbg !4 {
entry:
  %c = call i32 @strcmp(ptr %a, ptr %b) #3, !dbg !8
  ret i32 %c
}

define void @second(ptr %a, ptr %b, i32 %n) #2 {
entry:
  %p = call ptr @strcpy(ptr %a, ptr %b) #4
  br label %outer
outer:
  %i = phi i32 [ 0, %entry ], [ %i.next, %outer.latch ]
  br label %inner
inner:
  %j = phi i32 [ 0, %outer ], [ %j.next, %inner ]
  %j.next = add i32 %j, 1
  %c1 = icmp slt i32 %j.next, %n
  br i1 %c1, label %inner, label %outer.latch, !llvm.loop !12
outer.latch:
  %i.next = add i32 %i, 1
  %c2 = icmp slt i32 %i.next, %n
  br i1 %c2, label %outer, label %exit
exit:
  %r = call i32 @strcmp(ptr %a, ptr %b) #3
  ret void
}

attributes #0 = { nounwind readonly }
attributes #1 = { nounwind }
attributes #2 = { noinline }
attributes #3 = { cold }
attributes #4 = { minsize }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "p", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, globals: !9)
!1 = !DIFile(filename: "t.c", directory: "/d")
!2 = !{i32 2, !"Debug Info Version", i32 3}
!3 = !{i32 7, !"Dwarf Version", i32 5}
!4 = distinct !DISubprogram(name: "first", scope: !1, file: !1, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)
!5 = !DISubroutineType(types: !6)
!6 = !{!7}
!7 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!8 = !DILocation(line: 2, column: 3, scope: !4)
!9 = !{!10}
!10 = !DIGlobalVariableExpression(var: !11, expr: !DIExpression())
!11 = distinct !DIGlobalVariable(name: "g", scope: !0, file: !1, line: 3, type: !7, isLocal: false, isDefinition: true)
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.mustprogress"}
