declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg)
declare i32 @llvm.ctpop.i32(i32)
declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare i32 @printf(ptr noundef, ...)

@fmt = private constant [4 x i8] c"%d\0A\00"

define i32 @calls(ptr %dst, ptr %src, i32 %x) #0 {
  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 32, i1 false)
  %pc = call i32 @llvm.ctpop.i32(i32 %x)
  %ov = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %pc, i32 %x)
  %v = extractvalue { i32, i1 } %ov, 0
  %r = tail call i32 (ptr, ...) @printf(ptr noundef @fmt, i32 noundef %v) #1
  %fp = call fastcc i32 @callee(i32 signext %r)
  ret i32 %fp
}

define internal fastcc i32 @callee(i32 signext %a) nounwind {
  ret i32 %a
}

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="all" "target-cpu"="x86-64" }
attributes #1 = { nounwind }
