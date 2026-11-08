define double @casts(i32 %x, float %f, ptr %p) {
  %t = trunc i32 %x to i8
  %s = sext i8 %t to i64
  %z = zext i8 %t to i16
  %fp = sitofp i64 %s to double
  %ufp = uitofp nneg i16 %z to float
  %fi = fptosi float %f to i32
  %fu = fptoui float %f to i64
  %ext = fpext float %ufp to double
  %tr = fptrunc double %fp to float
  %pi = ptrtoint ptr %p to i64
  %ip = inttoptr i64 %pi to ptr
  %bc = bitcast i32 %fi to float
  %sum = fadd fast double %fp, %ext
  %neg = fneg double %sum
  %cmp = fcmp olt double %neg, 0.000000e+00
  %m = fmul nnan ninf double %neg, 0x7FF0000000000000
  %d = fdiv double %m, 3.000000e+00
  %res = select i1 %cmp, double %d, double 1.0e-300
  ret double %res
}
