; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/2008-06-13-LinkOnceRedefinition.ll
define linkonce void @foo(i32 %x) { ret void }
