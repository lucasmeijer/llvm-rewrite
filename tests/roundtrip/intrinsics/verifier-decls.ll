; Declarations of intrinsics that LLVM's Verifier tests call (tests/imported/llvm/Verifier) but that no valid test
; declares, so that their attributes are known to gen_intrinsics.py (Intrinsic::getAttributes).

declare void @llvm.gcroot(ptr, ptr)
declare ptr @llvm.gcread(ptr, ptr)
declare void @llvm.gcwrite(ptr, ptr, ptr)
declare i64 @llvm.get.dynamic.area.offset.i64()
declare <4 x float> @llvm.matrix.transpose.v4f32(<4 x float>, i32, i32)
declare ptr @llvm.preserve.struct.access.index.p0.p0(ptr, i32, i32)
declare void @llvm.reloc.none(metadata)
declare ptr @llvm.structured.alloca.p0()

define void @f(ptr %p) {
  call void @llvm.reloc.none(metadata !"sym")
  ret void
}
declare void @llvm.experimental.patchpoint.void(i64, i32, ptr, i32, ...)
declare i64 @llvm.experimental.patchpoint.i64(i64, i32, ptr, i32, ...)
declare void @llvm.hwasan.check.memaccess(ptr, ptr, i32)
declare ptr @llvm.returnaddress(i32)
declare ptr @llvm.frameaddress(i32)
declare void @llvm.memcpy.p0.p0.i32(ptr nocapture, ptr nocapture, i32, i1)
declare void @llvm.memcpy.inline.p0.p0.i32(ptr nocapture, ptr nocapture, i32, i1)
declare void @llvm.memmove.p0.p0.i32(ptr nocapture, ptr nocapture, i32, i1)
declare void @llvm.memset.p0.i32(ptr nocapture, i8, i32, i1)
declare void @llvm.memset.inline.p0.i32(ptr nocapture, i8, i32, i1)
declare void @llvm.experimental.memset.pattern.p0.i32.i32(ptr nocapture, i32, i32, i1)
declare i64 @llvm.objectsize.i64.p0(ptr, i1, i1, i1)
declare i64 @llvm.smul.fix.i64(i64, i64, i32)
declare i64 @llvm.smul.fix.sat.i64(i64, i64, i32)
declare i64 @llvm.umul.fix.i64(i64, i64, i32)
declare i64 @llvm.umul.fix.sat.i64(i64, i64, i32)
declare ptr @llvm.invariant.start.p0(i64, ptr)
declare void @llvm.invariant.end.p0(ptr, i64, ptr)
declare void @llvm.prefetch(ptr, i32, i32, i32)
declare ptr @llvm.localrecover(ptr, ptr, i32)
declare token @llvm.experimental.gc.statepoint.p0(i64, i32, ptr, i32, i32, ...)
declare void @llvm.eh.sjlj.callsite(i32)
