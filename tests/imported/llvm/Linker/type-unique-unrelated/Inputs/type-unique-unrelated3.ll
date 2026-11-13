; @origin: llvm/test/Linker/Inputs/type-unique-unrelated3.ll (llvmorg-23.1.5)
%t = type { ptr }
declare %t @f()

define %t @g() {
 %x = call %t @f()
 ret %t %x
}
