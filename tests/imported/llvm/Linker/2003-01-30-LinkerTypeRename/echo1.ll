; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/2003-01-30-LinkerTypeRename.ll
%Ty = type opaque @GV = external global %Ty
