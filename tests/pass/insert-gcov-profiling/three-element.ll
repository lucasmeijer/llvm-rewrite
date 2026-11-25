; Hand-written: a three-element !llvm.gcov node gives the notes and data file names verbatim; a second, DWO
; compile unit is skipped; a function using a scope-based EH personality and a noprofile function get no coverage.
; @opt-files: -passes=insert-gcov-profiling
target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define void @_Z3foov() !dbg !5 {
entry:
  call void @g(), !dbg !8
  ret void, !dbg !9
}

define void @np() noprofile !dbg !15 {
  ret void, !dbg !16
}

define void @seh() personality ptr @__CxxFrameHandler3 !dbg !17 {
  ret void, !dbg !18
}

declare void @g()
declare i32 @__CxxFrameHandler3(...)

!llvm.gcov = !{!10}
!llvm.dbg.cu = !{!0, !11}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_C_plus_plus, producer: "hand-written", isOptimized: false, emissionKind: FullDebug, file: !1)
!1 = !DIFile(filename: "three.cc", directory: "/nonexistent")
!4 = !{i32 1, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "foo", linkageName: "_Z3foov", line: 3, isDefinition: true, flags: DIFlagPrototyped, isOptimized: false, unit: !0, scopeLine: 3, file: !1, scope: !1, type: !7)
!7 = !DISubroutineType(types: !{null})
!8 = !DILocation(line: 4, scope: !5)
!9 = !DILocation(line: 5, scope: !5)
!10 = !{!"aaa.gcno", !"bbb.gcda", !0}
!11 = distinct !DICompileUnit(language: DW_LANG_C99, producer: "hand-written", isOptimized: false, emissionKind: FullDebug, file: !12, splitDebugFilename: "x.dwo", dwoId: 1234)
!12 = !DIFile(filename: "dwo.c", directory: "/nonexistent")
!15 = distinct !DISubprogram(name: "np", line: 10, isDefinition: true, isOptimized: false, unit: !0, scopeLine: 10, file: !1, scope: !1, type: !7)
!16 = !DILocation(line: 11, scope: !15)
!17 = distinct !DISubprogram(name: "seh", line: 20, isDefinition: true, isOptimized: false, unit: !0, scopeLine: 20, file: !1, scope: !1, type: !7)
!18 = !DILocation(line: 21, scope: !17)
