; @origin: llvm/test/Transforms/SCCP/apint-bigint.ll (llvmorg-23.1.5)
; @opt: -passes=sccp
; RUN: opt < %s -passes=sccp -S | not grep xor

define i11129 @test1() {
        %B = shl i11129 1, 11128 
        %C = sub i11129 %B, 1
        %D = xor i11129 %B, %C
        
	ret i11129 %D
}
