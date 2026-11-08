define i64 @f(i64 %a, i64 %b, i32) {
  %sum = add i64 %a, %b
  %2 = zext i32 %0 to i64
  %3 = mul nsw i64 %sum, %2
  %named.1 = sub nuw i64 %3, 1
  ret i64 %named.1
}

declare i32 @ext(ptr, ...)
