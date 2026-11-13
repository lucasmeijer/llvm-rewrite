; @origin: llvm/test/Linker/Inputs/byref-type-input.ll (llvmorg-23.1.5)
%a = type { i64 }
%struct = type { i32, i8 }

define void @g(ptr byref(%a)) {
  ret void
}

declare void @baz(ptr byref(%struct))

define void @foo(ptr byref(%struct) %a) {
  call void @baz(ptr byref(%struct) %a)
  ret void
}
