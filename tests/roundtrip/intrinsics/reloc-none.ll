; llvm.reloc.none (created by InstCombine's optimizeModularFormat): its declaration attributes
define void @f() {
  call void @llvm.reloc.none(metadata !"impl_float")
  ret void
}

declare void @llvm.reloc.none(metadata)
