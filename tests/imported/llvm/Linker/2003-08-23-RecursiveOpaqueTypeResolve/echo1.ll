; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/2003-08-23-RecursiveOpaqueTypeResolve.ll
%M = type { ptr, ptr }
