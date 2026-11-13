; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/2003-11-18-TypeResolution.ll
%T1 = type opaque  @GVar = external global %T1*
