; getGEPCost's isLegalAddressingMode with a global base (X86Subtarget::classifyGlobalReference): Darwin
; (isStrongDefinitionForLinker), Windows (dllimport, MinGW), 32-bit ELF and 64-bit ELF.
; @analysis: '-passes=print<cost-model>' -cost-kind=code-size -mtriple=x86_64-apple-macosx10.15
; @analysis: '-passes=print<cost-model>' -cost-kind=code-size -mtriple=x86_64-pc-windows-msvc
; @analysis: '-passes=print<cost-model>' -cost-kind=code-size -mtriple=x86_64-pc-windows-gnu
; @analysis: '-passes=print<cost-model>' -cost-kind=code-size -mtriple=i686-unknown-linux-gnu
; @analysis: '-passes=print<cost-model>' -cost-kind=code-size -mtriple=x86_64-unknown-linux-gnu
@strong = global [16 x i32] zeroinitializer
@weak = weak global [16 x i32] zeroinitializer
@ext = external global [16 x i32]
@imp = external dllimport global [16 x i32]
@hid = hidden global [16 x i32] zeroinitializer
define i32 @f(i64 %i) {
  %p1 = getelementptr [16 x i32], ptr @strong, i64 0, i64 3
  %l1 = load i32, ptr %p1
  %p2 = getelementptr [16 x i32], ptr @weak, i64 0, i64 %i
  %l2 = load i32, ptr %p2
  %p3 = getelementptr [16 x i32], ptr @ext, i64 0, i64 2
  %l3 = load i32, ptr %p3
  %p4 = getelementptr [16 x i32], ptr @imp, i64 0, i64 1
  %l4 = load i32, ptr %p4
  %p5 = getelementptr [16 x i32], ptr @hid, i64 0, i64 %i
  %l5 = load i32, ptr %p5
  %s1 = add i32 %l1, %l2
  %s2 = add i32 %l3, %l4
  %s3 = add i32 %s1, %s2
  %s4 = add i32 %s3, %l5
  ret i32 %s4
}
