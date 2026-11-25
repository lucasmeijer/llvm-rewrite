; Intrinsics that passes create (pgo-instr-gen -pgo-temporal-instrumentation: llvm.instrprof.timestamp),
; declared here so that impl/jai/gen/gen_intrinsics.py sees their attributes.
define void @f(ptr %name) {
  call void @llvm.instrprof.timestamp(ptr %name, i64 0, i32 1, i32 0)
  ret void
}

declare void @llvm.instrprof.timestamp(ptr, i64, i32, i32)
