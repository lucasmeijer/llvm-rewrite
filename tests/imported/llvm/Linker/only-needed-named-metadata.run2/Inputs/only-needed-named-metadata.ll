; @origin: llvm/test/Linker/Inputs/only-needed-named-metadata.ll (llvmorg-23.1.5)
@X = external global i32

declare i32 @foo()

define void @bar() {
	load i32, ptr @X
	call i32 @foo()
	ret void
}
