; @origin: `echo ... | llvm-as` in a RUN line of llvm/test/Linker/2003-08-23-GlobalVarLinking.ll
%T1 = type opaque %T2 = type opaque @S = external global { i32, %T1* } declare void @F(%T2*)
