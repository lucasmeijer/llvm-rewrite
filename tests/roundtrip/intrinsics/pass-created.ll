; Intrinsics that passes create (ee-instrument: llvm.returnaddress; rel-lookup-table-converter:
; llvm.load.relative), declared here so that
; impl/jai/gen/gen_intrinsics.py sees their attributes.
define ptr @caller() {
  %ra = call ptr @llvm.returnaddress.p0(i32 0)
  ret ptr %ra
}

declare ptr @llvm.returnaddress.p0(i32 immarg)

; rel-lookup-table-converter creates llvm.load.relative
define ptr @load_rel(ptr %p, i64 %o) {
  %r = call ptr @llvm.load.relative.i64(ptr %p, i64 %o)
  ret ptr %r
}

declare ptr @llvm.load.relative.i64(ptr, i64)
