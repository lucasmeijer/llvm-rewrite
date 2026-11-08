; @origin: llvm/test/Transforms/DeadArgElim/2006-06-27-struct-ret.ll (llvmorg-23.1.5)
; @opt: -passes=deadargelim
; RUN: opt < %s -passes=deadargelim -disable-output

define internal void @build_delaunay(ptr sret({ i32 })  %agg.result) {
        ret void
}

define void @test() {
        call void @build_delaunay(ptr sret({ i32 }) null)
        ret void
}

