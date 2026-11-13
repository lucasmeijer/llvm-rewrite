; @origin: llvm/test/Linker/Inputs/type-unique-unrelated2.ll (llvmorg-23.1.5)
%t = type { ptr }
declare %t @g()

define %t @g2() {
 %x = call %t @g()
 ret %t %x
}
