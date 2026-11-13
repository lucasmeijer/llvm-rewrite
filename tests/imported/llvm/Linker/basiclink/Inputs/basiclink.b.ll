; @origin: llvm/test/Linker/Inputs/basiclink.b.ll (llvmorg-23.1.5)
declare ptr @foo(...)
define ptr @bar() {
	%ret = call ptr (...) @foo( i32 123 )
	ret ptr %ret
}
@baz = global i32 0
