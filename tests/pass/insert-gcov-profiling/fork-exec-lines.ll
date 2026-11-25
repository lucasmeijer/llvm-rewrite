; Hand-written: fork / exec calls (AddFlushBeforeForkAndExec: __gcov_fork, llvm_writeout_files /
; llvm_reset_counters, block splits, and no spanning-tree optimization), line records through lexical blocks, a
; DILexicalBlockFile in another file (a new GCOVLines group), an inlined location (skipped: another subprogram),
; implicit code and line 0 (skipped), a loop and a switch with critical edges, an artificial function (no entry
; line), and two compile-unit-relative file names (the relative one does not exist: directory + name).
; @opt-files: -passes=insert-gcov-profiling
; @opt-files: -passes=insert-gcov-profiling -gcov-atomic-counter
target datalayout = "e-m:e-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i32 @main(i32 %n, ptr %argv) !dbg !5 {
entry:
  %pid = call i32 @fork(), !dbg !8
  %z = icmp eq i32 %pid, 0, !dbg !9
  br i1 %z, label %child, label %loop, !dbg !9

child:
  %r = call i32 @execv(ptr null, ptr %argv), !dbg !10
  br label %loop, !dbg !11

loop:
  %i = phi i32 [ 0, %entry ], [ 0, %child ], [ %i1, %latch ]
  %i1 = add i32 %i, 1, !dbg !12
  switch i32 %i, label %latch [
    i32 3, label %exit
    i32 5, label %side
  ], !dbg !13

side:
  call void @g(), !dbg !14
  call void @g(), !dbg !15
  call void @g(), !dbg !16
  br label %latch, !dbg !17

latch:
  %c = icmp slt i32 %i1, %n, !dbg !18
  br i1 %c, label %loop, label %exit, !dbg !18

exit:
  ret i32 0, !dbg !19
}

define internal void @_GLOBAL__sub_I_x() !dbg !30 {
  call void @g(), !dbg !31
  call void @g(), !dbg !32
  ret void, !dbg !32
}

declare i32 @fork()
declare i32 @execv(ptr, ptr)
declare void @g()

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!4}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, producer: "hand-written", isOptimized: false, emissionKind: FullDebug, file: !1)
!1 = !DIFile(filename: "src/fork.c", directory: "/nonexistent")
!2 = !DIFile(filename: "inc/fork.h", directory: "/nonexistent")
!4 = !{i32 1, !"Debug Info Version", i32 3}
!5 = distinct !DISubprogram(name: "main", line: 10, isDefinition: true, flags: DIFlagPrototyped, isOptimized: false, unit: !0, scopeLine: 10, file: !1, scope: !1, type: !7)
!7 = !DISubroutineType(types: !{null})
!8 = !DILocation(line: 11, scope: !5)
!9 = !DILocation(line: 12, scope: !20)
!10 = !DILocation(line: 13, scope: !20)
!11 = !DILocation(line: 13, scope: !20, isImplicitCode: true)
!12 = !DILocation(line: 15, scope: !21)
!13 = !DILocation(line: 16, scope: !21)
!14 = !DILocation(line: 3, scope: !22)
!15 = !DILocation(line: 4, scope: !23, inlinedAt: !24)
!16 = !DILocation(line: 0, scope: !5)
!17 = !DILocation(line: 18, scope: !5)
!18 = !DILocation(line: 19, scope: !5)
!19 = !DILocation(line: 20, scope: !5)
!20 = distinct !DILexicalBlock(scope: !5, file: !1, line: 12, column: 3)
!21 = distinct !DILexicalBlock(scope: !20, file: !1, line: 14, column: 3)
!22 = !DILexicalBlockFile(scope: !21, file: !2, discriminator: 0)
!23 = distinct !DISubprogram(name: "inl", line: 2, isDefinition: true, isOptimized: false, unit: !0, scopeLine: 2, file: !2, scope: !2, type: !7)
!24 = !DILocation(line: 17, scope: !21)
!30 = distinct !DISubprogram(name: "_GLOBAL__sub_I_x", line: 40, isDefinition: true, flags: DIFlagArtificial, isOptimized: false, unit: !0, scopeLine: 40, file: !1, scope: !1, type: !7)
!31 = !DILocation(line: 41, scope: !30)
!32 = !DILocation(line: 0, scope: !30)
