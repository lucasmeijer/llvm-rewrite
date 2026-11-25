; @origin: llvm/test/CodeGen/X86/dwarf_eh_resume.ll (llvmorg-23.1.5), copied with these directives because its RUN lines mix stderr and -S output or are not imported
; @opt: -mtriple=x86_64-linux-gnu '-passes=require<libcall-lowering-info>,dwarf-eh-prepare'
; @opt: -mtriple=x86_64-linux-gnu '-passes=require<libcall-lowering-info>,dwarf-eh-prepare' -codegen-opt-level=2
; RUN: opt -mtriple=x86_64-linux-gnu -dwarf-eh-prepare -S %s | FileCheck %s
; RUN: opt -mtriple=x86_64-linux-gnu -passes='require<libcall-lowering-info>,dwarf-eh-prepare' -S %s | FileCheck %s

declare i32 @hoge(...)

; Check that 'resume' is lowered to _Unwind_Resume which marked as 'noreturn'
define void @pluto() align 2 personality ptr @hoge {
;CHECK: call void @_Unwind_Resume(ptr %exn.obj) [[A:#.*]]
;CHECK: attributes [[A]] = { noreturn }
bb:
  invoke void @spam()
          to label %bb1 unwind label %bb2

bb1:                                              ; preds = %bb
  ret void

bb2:                                              ; preds = %bb
  %tmp = landingpad { ptr, i32 }
          cleanup
  resume { ptr, i32 } %tmp

}

declare void @spam()
