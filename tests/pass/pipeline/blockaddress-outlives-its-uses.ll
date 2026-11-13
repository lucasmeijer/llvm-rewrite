; A blockaddress constant lives on after its last use is deleted (LLVM 23: it is not a user of its function, so
; removeDeadConstantUsers never destroys it), so its block stays address-taken and simplifycfg keeps it as an
; indirectbr destination. Here instcombine deletes the dead stores, globalopt calls removeDeadConstantUsers on @f.
; @opt: -passes='function(instcombine),globalopt,function(simplifycfg)'
define void @f(ptr %P, ptr %Q) {
entry:
  store ptr blockaddress(@f, %BB0), ptr %P
  store ptr blockaddress(@f, %BB1), ptr %P
  store ptr blockaddress(@f, %BB2), ptr %P
  %t = load ptr, ptr %Q
  indirectbr ptr %t, [label %BB0, label %BB1, label %BB2]
BB0:
  call void @A()
  ret void
BB1:
  call void @B()
  ret void
BB2:
  call void @C()
  ret void
}
declare void @A()
declare void @B()
declare void @C()
