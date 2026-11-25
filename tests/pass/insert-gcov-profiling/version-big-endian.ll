; Hand-written: GCOVProfiling's .gcno writer on a big-endian datalayout ("gcno" magic, words written big-endian),
; -default-gcov-version (versions below 111 become B11*; B21* is kept), and a two-element !llvm.gcov node naming the
; notes file (relative: written into the working directory; the gcda path is that name with .gcda).
; @opt-files: -passes=insert-gcov-profiling
; @opt-files: -passes=insert-gcov-profiling -default-gcov-version=B21*
; @opt-files: -passes=insert-gcov-profiling -default-gcov-version=A99*
target datalayout = "E"

define i32 @test(i32 %x) !dbg !5 {
entry:
  %c = icmp sgt i32 %x, 0, !dbg !8
  br i1 %c, label %pos, label %neg, !dbg !8

pos:
  %a = add i32 %x, 1, !dbg !9
  br label %done, !dbg !9

neg:
  %b = sub i32 0, %x, !dbg !10
  br label %done, !dbg !10

done:
  %r = phi i32 [ %a, %pos ], [ %b, %neg ]
  ret i32 %r, !dbg !11
}

!llvm.gcov = !{!12}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, producer: "hand-written", isOptimized: false, emissionKind: FullDebug, file: !1)
!1 = !DIFile(filename: "version.c", directory: "/nonexistent/dir")
!4 = !{i32 1, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "test", line: 1, isDefinition: true, flags: DIFlagPrototyped, isOptimized: false, unit: !0, scopeLine: 1, file: !1, scope: !1, type: !7)
!7 = !DISubroutineType(types: !{null})
!8 = !DILocation(line: 2, scope: !5)
!9 = !DILocation(line: 3, scope: !5)
!10 = !DILocation(line: 5, scope: !5)
!11 = !DILocation(line: 7, scope: !5)
!12 = !{!"version.ll", !0}
