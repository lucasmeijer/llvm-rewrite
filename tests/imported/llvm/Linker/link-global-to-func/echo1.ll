; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/link-global-to-func.ll
declare void @__eprintf(ptr, ptr, i32, ptr) noreturn     define void @foo() {      tail call void @__eprintf( ptr undef, ptr undef, i32 4, ptr null ) noreturn nounwind       unreachable }
