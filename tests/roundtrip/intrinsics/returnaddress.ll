; Intrinsics that passes create (ee-instrument: llvm.returnaddress), declared here so that
; impl/jai/gen/gen_intrinsics.py sees their attributes.
define ptr @caller() {
  %ra = call ptr @llvm.returnaddress.p0(i32 0)
  ret ptr %ra
}

declare ptr @llvm.returnaddress.p0(i32 immarg)
