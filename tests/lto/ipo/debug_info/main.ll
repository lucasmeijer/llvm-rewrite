; @source: tests/lto/src/ipo/debug_info/main.c
; @opt: -passes='lto-pre-link<O2>'
; @generated: clang -O2 -flto -Xclang -disable-llvm-passes -g -S -emit-llvm (LLVM 23.1.5) by harness/run from-c
; ModuleID = 'tests/lto/src/ipo/debug_info/main.c'
source_filename = "tests/lto/src/ipo/debug_info/main.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.point = type { i32, i32 }

@.str = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1, !dbg !0

; Function Attrs: nounwind uwtable
define dso_local i32 @main() #0 !dbg !20 {
  %1 = alloca i32, align 4
  %2 = alloca %struct.point, align 4
  %3 = alloca i32, align 4
  %4 = alloca i32, align 4
  %5 = alloca %struct.point, align 4
  store i32 0, ptr %1, align 4
  call void @llvm.lifetime.start.p0(ptr %2) #4, !dbg !36
    #dbg_declare(ptr %2, !25, !DIExpression(), !37)
  call void @llvm.memset.p0.i64(ptr align 4 %2, i8 0, i64 8, i1 false), !dbg !38
  call void @llvm.lifetime.start.p0(ptr %3) #4, !dbg !39
    #dbg_declare(ptr %3, !30, !DIExpression(), !40)
  store i32 0, ptr %3, align 4, !dbg !41, !tbaa !42
  call void @llvm.lifetime.start.p0(ptr %4) #4, !dbg !43
    #dbg_declare(ptr %4, !31, !DIExpression(), !44)
  store i32 0, ptr %4, align 4, !dbg !45, !tbaa !42
  br label %6, !dbg !43

6:                                                ; preds = %22, %0
  %7 = load i32, ptr %4, align 4, !dbg !46, !tbaa !42
  %8 = icmp slt i32 %7, 5, !dbg !47
  br i1 %8, label %10, label %9, !dbg !48

9:                                                ; preds = %6
  call void @llvm.lifetime.end.p0(ptr %4) #4, !dbg !49
  br label %25

10:                                               ; preds = %6
  call void @llvm.lifetime.start.p0(ptr %5) #4, !dbg !50
    #dbg_declare(ptr %5, !33, !DIExpression(), !51)
  %11 = getelementptr inbounds nuw %struct.point, ptr %5, i32 0, i32 0, !dbg !52
  %12 = load i32, ptr %4, align 4, !dbg !53, !tbaa !42
  %13 = mul nsw i32 %12, 3, !dbg !54
  store i32 %13, ptr %11, align 4, !dbg !55, !tbaa !56
  %14 = getelementptr inbounds nuw %struct.point, ptr %5, i32 0, i32 1, !dbg !52
  %15 = load i32, ptr %4, align 4, !dbg !58, !tbaa !42
  %16 = sub nsw i32 0, %15, !dbg !59
  store i32 %16, ptr %14, align 4, !dbg !55, !tbaa !60
  %17 = load i64, ptr %2, align 4, !dbg !61
  %18 = load i64, ptr %5, align 4, !dbg !61
  %19 = call i32 @manhattan(i64 %17, i64 %18), !dbg !61
  %20 = load i32, ptr %3, align 4, !dbg !62, !tbaa !42
  %21 = add nsw i32 %20, %19, !dbg !63
  store i32 %21, ptr %3, align 4, !dbg !64, !tbaa !42
  call void @llvm.lifetime.end.p0(ptr %5) #4, !dbg !65
  br label %22, !dbg !66

22:                                               ; preds = %10
  %23 = load i32, ptr %4, align 4, !dbg !67, !tbaa !42
  %24 = add nsw i32 %23, 1, !dbg !68
  store i32 %24, ptr %4, align 4, !dbg !69, !tbaa !42
  br label %6, !dbg !49, !llvm.loop !70

25:                                               ; preds = %9
  %26 = load i32, ptr %3, align 4, !dbg !74, !tbaa !42
  %27 = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %26), !dbg !75
  call void @llvm.lifetime.end.p0(ptr %3) #4, !dbg !76
  call void @llvm.lifetime.end.p0(ptr %2) #4, !dbg !76
  ret i32 0, !dbg !77
}

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(ptr captures(none)) #1

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr writeonly captures(none), i8, i64, i1 immarg) #2

declare !dbg !78 i32 @manhattan(i64, i64) #3

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(ptr captures(none)) #1

declare !dbg !81 i32 @printf(ptr noundef, ...) #3

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { nocallback nofree nosync nounwind willreturn memory(argmem: write) }
attributes #3 = { "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nounwind }

!llvm.dbg.cu = !{!7}
!llvm.module.flags = !{!9, !10, !11, !12, !13}
!llvm.ident = !{!14}
!llvm.errno.tbaa = !{!15}

!0 = !DIGlobalVariableExpression(var: !1, expr: !DIExpression())
!1 = distinct !DIGlobalVariable(scope: null, file: !2, line: 8, type: !3, isLocal: true, isDefinition: true)
!2 = !DIFile(filename: "tests/lto/src/ipo/debug_info/main.c", directory: "/work-wt/jai_lto", checksumkind: CSK_MD5, checksum: "84b5dd95caab37a46e9f0bef1ddc89a3")
!3 = !DICompositeType(tag: DW_TAG_array_type, baseType: !4, size: 32, elements: !5)
!4 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed_char)
!5 = !{!6}
!6 = !DISubrange(count: 4)
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !2, producer: "clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)", isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, globals: !8, splitDebugInlining: false, nameTableKind: None)
!8 = !{!0}
!9 = !{i32 7, !"Dwarf Version", i32 5}
!10 = !{i32 2, !"Debug Info Version", i32 3}
!11 = !{i32 8, !"PIC Level", i32 2}
!12 = !{i32 7, !"PIE Level", i32 2}
!13 = !{i32 7, !"uwtable", i32 2}
!14 = !{!"clang version 23.1.5 (https://github.com/llvm/llvm-project 392dfff97d29b59d77e5cac6d4b6ef2585fe7117)"}
!15 = !{!16, !17, i64 0}
!16 = !{!"__libc_errno", !17, i64 0}
!17 = !{!"int", !18, i64 0}
!18 = !{!"omnipotent char", !19, i64 0}
!19 = !{!"Simple C/C++ TBAA"}
!20 = distinct !DISubprogram(name: "main", scope: !2, file: !2, line: 4, type: !21, scopeLine: 4, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !7, retainedNodes: !24, keyInstructions: true)
!21 = !DISubroutineType(types: !22)
!22 = !{!23}
!23 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!24 = !{!25, !30, !31, !33}
!25 = !DILocalVariable(name: "o", scope: !20, file: !2, line: 5, type: !26)
!26 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "point", file: !2, line: 2, size: 64, elements: !27)
!27 = !{!28, !29}
!28 = !DIDerivedType(tag: DW_TAG_member, name: "x", scope: !26, file: !2, line: 2, baseType: !23, size: 32)
!29 = !DIDerivedType(tag: DW_TAG_member, name: "y", scope: !26, file: !2, line: 2, baseType: !23, size: 32, offset: 32)
!30 = !DILocalVariable(name: "total", scope: !20, file: !2, line: 6, type: !23)
!31 = !DILocalVariable(name: "i", scope: !32, file: !2, line: 7, type: !23)
!32 = distinct !DILexicalBlock(scope: !20, file: !2, line: 7, column: 3)
!33 = !DILocalVariable(name: "p", scope: !34, file: !2, line: 7, type: !26)
!34 = distinct !DILexicalBlock(scope: !35, file: !2, line: 7, column: 31)
!35 = distinct !DILexicalBlock(scope: !32, file: !2, line: 7, column: 3)
!36 = !DILocation(line: 5, column: 3, scope: !20)
!37 = !DILocation(line: 5, column: 16, scope: !20)
!38 = !DILocation(line: 5, column: 16, scope: !20, atomGroup: 1, atomRank: 1)
!39 = !DILocation(line: 6, column: 3, scope: !20)
!40 = !DILocation(line: 6, column: 7, scope: !20)
!41 = !DILocation(line: 6, column: 7, scope: !20, atomGroup: 2, atomRank: 1)
!42 = !{!17, !17, i64 0}
!43 = !DILocation(line: 7, column: 8, scope: !32)
!44 = !DILocation(line: 7, column: 12, scope: !32)
!45 = !DILocation(line: 7, column: 12, scope: !32, atomGroup: 3, atomRank: 1)
!46 = !DILocation(line: 7, column: 19, scope: !35)
!47 = !DILocation(line: 7, column: 21, scope: !35, atomGroup: 4, atomRank: 1)
!48 = !DILocation(line: 7, column: 3, scope: !32, atomGroup: 5, atomRank: 1)
!49 = !DILocation(line: 7, column: 3, scope: !35)
!50 = !DILocation(line: 7, column: 33, scope: !34)
!51 = !DILocation(line: 7, column: 46, scope: !34)
!52 = !DILocation(line: 7, column: 50, scope: !34)
!53 = !DILocation(line: 7, column: 51, scope: !34)
!54 = !DILocation(line: 7, column: 53, scope: !34, atomGroup: 6, atomRank: 2)
!55 = !DILocation(line: 7, column: 50, scope: !34, atomGroup: 6, atomRank: 1)
!56 = !{!57, !17, i64 0}
!57 = !{!"point", !17, i64 0, !17, i64 4}
!58 = !DILocation(line: 7, column: 59, scope: !34)
!59 = !DILocation(line: 7, column: 58, scope: !34, atomGroup: 6, atomRank: 2)
!60 = !{!57, !17, i64 4}
!61 = !DILocation(line: 7, column: 72, scope: !34)
!62 = !DILocation(line: 7, column: 69, scope: !34)
!63 = !DILocation(line: 7, column: 69, scope: !34, atomGroup: 7, atomRank: 2)
!64 = !DILocation(line: 7, column: 69, scope: !34, atomGroup: 7, atomRank: 1)
!65 = !DILocation(line: 7, column: 89, scope: !35)
!66 = !DILocation(line: 7, column: 89, scope: !34, atomGroup: 9, atomRank: 1)
!67 = !DILocation(line: 7, column: 27, scope: !35)
!68 = !DILocation(line: 7, column: 27, scope: !35, atomGroup: 8, atomRank: 2)
!69 = !DILocation(line: 7, column: 27, scope: !35, atomGroup: 8, atomRank: 1)
!70 = distinct !{!70, !71, !72, !73}
!71 = !DILocation(line: 7, column: 3, scope: !32)
!72 = !DILocation(line: 7, column: 89, scope: !32)
!73 = !{!"llvm.loop.mustprogress"}
!74 = !DILocation(line: 8, column: 18, scope: !20)
!75 = !DILocation(line: 8, column: 3, scope: !20)
!76 = !DILocation(line: 10, column: 1, scope: !20)
!77 = !DILocation(line: 9, column: 3, scope: !20, atomGroup: 11, atomRank: 1)
!78 = !DISubprogram(name: "manhattan", scope: !2, file: !2, line: 3, type: !79, flags: DIFlagPrototyped, spFlags: DISPFlagOptimized)
!79 = !DISubroutineType(types: !80)
!80 = !{!23, !26, !26}
!81 = !DISubprogram(name: "printf", scope: !82, file: !82, line: 370, type: !83, flags: DIFlagPrototyped, spFlags: DISPFlagOptimized)
!82 = !DIFile(filename: "/usr/include/stdio.h", directory: "", checksumkind: CSK_MD5, checksum: "1737dfad03570987edca7e059644f741")
!83 = !DISubroutineType(types: !84)
!84 = !{!23, !85, null}
!85 = !DIDerivedType(tag: DW_TAG_restrict_type, baseType: !86)
!86 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !87, size: 64)
!87 = !DIDerivedType(tag: DW_TAG_const_type, baseType: !4)
