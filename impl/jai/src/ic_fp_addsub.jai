// InstCombine for fadd, fsub, fneg (InstCombineAddSub.cpp: visitFAdd, visitFSub, visitFNeg).
ic_visit_fadd :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_fsub :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
ic_visit_fneg :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
