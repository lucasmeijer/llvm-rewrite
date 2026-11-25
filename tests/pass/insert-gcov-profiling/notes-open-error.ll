; Hand-written: a notes file that cannot be created (its directory does not exist) is an LLVMContext error:
; opt reports it and fails after the pipeline. The data file name still gets into the IR (not compared here).
; @error: -passes=insert-gcov-profiling
define void @f() !dbg !5 {
  ret void, !dbg !8
}

!llvm.gcov = !{!12}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, producer: "hand-written", isOptimized: false, emissionKind: FullDebug, file: !1)
!1 = !DIFile(filename: "e.c", directory: "/nonexistent")
!4 = !{i32 1, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "f", line: 1, isDefinition: true, isOptimized: false, unit: !0, scopeLine: 1, file: !1, scope: !1, type: !7)
!7 = !DISubroutineType(types: !{null})
!8 = !DILocation(line: 2, scope: !5)
!12 = !{!"nonexistent-dir-for-gcov-test/e.ll", !0}
