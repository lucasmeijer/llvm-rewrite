// InstCombine for mul, div and rem: a port of llvm/lib/Transforms/InstCombine/InstCombineMulDivRem.cpp.

ic_visit_mul :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_udiv :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_sdiv :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_urem :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_srem :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_fmul :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_fdiv :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_frem :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
