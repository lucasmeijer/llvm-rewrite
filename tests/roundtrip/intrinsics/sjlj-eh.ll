; The intrinsics sjlj-eh-prepare declares (so that gen_intrinsics.py records their attributes).
declare ptr @llvm.frameaddress.p0(i32 immarg)
declare ptr @llvm.stacksave.p0()
declare void @llvm.stackrestore.p0(ptr)
declare void @llvm.eh.sjlj.setup.dispatch()
declare ptr @llvm.eh.sjlj.lsda()
declare void @llvm.eh.sjlj.callsite(i32 immarg)
declare void @llvm.eh.sjlj.functioncontext(ptr)
