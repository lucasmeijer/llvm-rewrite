; Hand-written: an -default-gcov-version that is not four characters is a fatal usage error.
; @error: -passes=insert-gcov-profiling -default-gcov-version=asdfasdf
define void @f() {
  ret void
}
