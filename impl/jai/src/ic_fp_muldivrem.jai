// InstCombine for fmul, fdiv, frem (InstCombineMulDivRem.cpp: visitFMul, visitFDiv, visitFRem and their helpers).
ic_visit_fmul :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_fdiv :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_frem :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
