; @origin: llvm/test/Linker/Inputs/byval-types-1.ll (llvmorg-23.1.5)
%struct = type {i32, i8}

declare void @baz(ptr byval(%struct))

define void @foo(ptr byval(%struct) %a) {
  call void @baz(ptr byval(%struct) %a)
  ret void
}
