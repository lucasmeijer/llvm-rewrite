; ConstantFoldConstant of a struct-indexed GEP with inrange: CastGEPIndices rewrites the i32 indices and must keep
; the inrange, so the zero-offset form folds to an i8 GEP with inrange instead of to the bare global.
; @opt: -passes=instcombine
@global = internal constant { [2 x ptr], [1 x ptr] } { [2 x ptr] [ptr null, ptr null], [1 x ptr] [ptr null] }
define ptr @f1() {
  ret ptr getelementptr inrange(0, 16) ({ [2 x ptr], [1 x ptr] }, ptr @global, i32 0, i32 0, i32 0)
}
define ptr @f2() {
  ret ptr getelementptr inrange(-8, 8) ({ [2 x ptr], [1 x ptr] }, ptr @global, i32 0, i32 0, i32 1)
}
define [0 x i1] @load_empty_array(ptr %p) {
  %a = load [0 x i1], ptr %p
  ret [0 x i1] %a
}
define {} @load_empty_struct(ptr %p) {
  %a = load {}, ptr %p
  ret {} %a
}
