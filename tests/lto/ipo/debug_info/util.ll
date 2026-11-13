; @source: tests/lto/src/ipo/debug_info/util.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -g -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/debug_info/util.c'
source_filename = "tests/lto/src/ipo/debug_info/util.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.point = type { i32, i32 }

; Function Attrs: nounwind uwtable
define dso_local i32 @manhattan(i64 %0, i64 %1) #0 !dbg !13 {
  %3 = alloca %struct.point, align 4
  %4 = alloca %struct.point, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  store i64 %0, ptr %3, align 4
  store i64 %1, ptr %4, align 4
    #dbg_declare(ptr %3, !22, !DIExpression(), !26)
    #dbg_declare(ptr %4, !23, !DIExpression(), !27)
  call void @llvm.lifetime.start.p0(ptr %5) #2, !dbg !28
    #dbg_declare(ptr %5, !24, !DIExpression(), !29)
  %7 = getelementptr inbounds nuw %struct.point, ptr %3, i32 0, i32 0, !dbg !30
  %8 = load i32, ptr %7, align 4, !dbg !30, !tbaa !31
  %9 = getelementptr inbounds nuw %struct.point, ptr %4, i32 0, i32 0, !dbg !33
  %10 = load i32, ptr %9, align 4, !dbg !33, !tbaa !31
  %11 = sub nsw i32 %8, %10, !dbg !34
  store i32 %11, ptr %5, align 4, !dbg !35, !tbaa !36
  call void @llvm.lifetime.start.p0(ptr %6) #2, !dbg !28
    #dbg_declare(ptr %6, !25, !DIExpression(), !37)
  %12 = getelementptr inbounds nuw %struct.point, ptr %3, i32 0, i32 1, !dbg !38
  %13 = load i32, ptr %12, align 4, !dbg !38, !tbaa !39
  %14 = getelementptr inbounds nuw %struct.point, ptr %4, i32 0, i32 1, !dbg !40
  %15 = load i32, ptr %14, align 4, !dbg !40, !tbaa !39
  %16 = sub nsw i32 %13, %15, !dbg !41
  store i32 %16, ptr %6, align 4, !dbg !42, !tbaa !36
  %17 = load i32, ptr %5, align 4, !dbg !43, !tbaa !36
  %18 = icmp slt i32 %17, 0, !dbg !44
  br i1 %18, label %19, label %22, !dbg !45

19:                                               ; preds = %2
  %20 = load i32, ptr %5, align 4, !dbg !46, !tbaa !36
  %21 = sub nsw i32 0, %20, !dbg !47
  br label %24, !dbg !43

22:                                               ; preds = %2
  %23 = load i32, ptr %5, align 4, !dbg !48, !tbaa !36
  br label %24, !dbg !43

24:                                               ; preds = %22, %19
  %25 = phi i32 [ %21, %19 ], [ %23, %22 ], !dbg !43
  %26 = load i32, ptr %6, align 4, !dbg !49, !tbaa !36
  %27 = icmp slt i32 %26, 0, !dbg !50
  br i1 %27, label %28, label %31, !dbg !51

28:                                               ; preds = %24
  %29 = load i32, ptr %6, align 4, !dbg !52, !tbaa !36
  %30 = sub nsw i32 0, %29, !dbg !53
  br label %33, !dbg !49

31:                                               ; preds = %24
  %32 = load i32, ptr %6, align 4, !dbg !54, !tbaa !36
  br label %33, !dbg !49

33:                                               ; preds = %31, %28
  %34 = phi i32 [ %30, %28 ], [ %32, %31 ], !dbg !49
  %35 = add nsw i32 %25, %34, !dbg !55
  call void @llvm.lifetime.end.p0(ptr %6) #2, !dbg !56
  call void @llvm.lifetime.end.p0(ptr %5) #2, !dbg !56
  ret i32 %35, !dbg !57
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nounwind }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3, !4, !5, !6}
!llvm.ident = !{!7}
!llvm.errno.tbaa = !{!8}

!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: None)
!1 = !DIFile(filename: "tests/lto/src/ipo/debug_info/util.c", directory: "/work-wt/jai_lto", checksumkind: CSK_MD5, checksum: "3fda40f13d38875e8267b8b40c34dd00")
!2 = !{i32 7, !"Dwarf Version", i32 5}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !{i32 8, !"PIC Level", i32 2}
!5 = !{i32 7, !"PIE Level", i32 2}
!6 = !{i32 7, !"uwtable", i32 2}
!7 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!8 = !{!9, !10, i64 0}
!9 = !{!"__libc_errno", !10, i64 0}
!10 = !{!"int", !11, i64 0}
!11 = !{!"omnipotent char", !12, i64 0}
!12 = !{!"Simple C/C++ TBAA"}
!13 = distinct !DISubprogram(name: "manhattan", scope: !1, file: !1, line: 2, type: !14, scopeLine: 2, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !21, keyInstructions: true)
!14 = !DISubroutineType(types: !15)
!15 = !{!16, !17, !17}
!16 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!17 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "point", file: !1, line: 1, size: 64, elements: !18)
!18 = !{!19, !20}
!19 = !DIDerivedType(tag: DW_TAG_member, name: "x", scope: !17, file: !1, line: 1, baseType: !16, size: 32)
!20 = !DIDerivedType(tag: DW_TAG_member, name: "y", scope: !17, file: !1, line: 1, baseType: !16, size: 32, offset: 32)
!21 = !{!22, !23, !24, !25}
!22 = !DILocalVariable(name: "a", arg: 1, scope: !13, file: !1, line: 2, type: !17)
!23 = !DILocalVariable(name: "b", arg: 2, scope: !13, file: !1, line: 2, type: !17)
!24 = !DILocalVariable(name: "dx", scope: !13, file: !1, line: 3, type: !16)
!25 = !DILocalVariable(name: "dy", scope: !13, file: !1, line: 3, type: !16)
!26 = !DILocation(line: 2, column: 28, scope: !13)
!27 = !DILocation(line: 2, column: 44, scope: !13)
!28 = !DILocation(line: 3, column: 3, scope: !13)
!29 = !DILocation(line: 3, column: 7, scope: !13)
!30 = !DILocation(line: 3, column: 14, scope: !13)
!31 = !{!32, !10, i64 0}
!32 = !{!"point", !10, i64 0, !10, i64 4}
!33 = !DILocation(line: 3, column: 20, scope: !13)
!34 = !DILocation(line: 3, column: 16, scope: !13, atomGroup: 1, atomRank: 2)
!35 = !DILocation(line: 3, column: 7, scope: !13, atomGroup: 1, atomRank: 1)
!36 = !{!10, !10, i64 0}
!37 = !DILocation(line: 3, column: 23, scope: !13)
!38 = !DILocation(line: 3, column: 30, scope: !13)
!39 = !{!32, !10, i64 4}
!40 = !DILocation(line: 3, column: 36, scope: !13)
!41 = !DILocation(line: 3, column: 32, scope: !13, atomGroup: 2, atomRank: 2)
!42 = !DILocation(line: 3, column: 23, scope: !13, atomGroup: 2, atomRank: 1)
!43 = !DILocation(line: 4, column: 11, scope: !13)
!44 = !DILocation(line: 4, column: 14, scope: !13, atomGroup: 4, atomRank: 2)
!45 = !DILocation(line: 4, column: 11, scope: !13, atomGroup: 4, atomRank: 1)
!46 = !DILocation(line: 4, column: 21, scope: !13)
!47 = !DILocation(line: 4, column: 20, scope: !13)
!48 = !DILocation(line: 4, column: 26, scope: !13)
!49 = !DILocation(line: 4, column: 33, scope: !13)
!50 = !DILocation(line: 4, column: 36, scope: !13, atomGroup: 5, atomRank: 2)
!51 = !DILocation(line: 4, column: 33, scope: !13, atomGroup: 5, atomRank: 1)
!52 = !DILocation(line: 4, column: 43, scope: !13)
!53 = !DILocation(line: 4, column: 42, scope: !13)
!54 = !DILocation(line: 4, column: 48, scope: !13)
!55 = !DILocation(line: 4, column: 30, scope: !13, atomGroup: 6, atomRank: 2)
!56 = !DILocation(line: 5, column: 1, scope: !13)
!57 = !DILocation(line: 4, column: 3, scope: !13, atomGroup: 6, atomRank: 1)
