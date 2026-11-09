// std::stable_sort exactly as GCC 12's libstdc++ implements it (bits/stl_algo.h: __stable_sort,
// __stable_sort_adaptive, __merge_sort_with_buffer, __chunk_insertion_sort, __insertion_sort,
// __unguarded_linear_insert, __merge_loop, __move_merge, __merge_adaptive, __move_merge_adaptive(_backward)).
// LLVM 23.1.5's opt is built with it, and some of LLVM's comparators are not strict weak orders (or make
// queries with side effects, such as DominatorTree::dominates), so the exact sequence of comparisons matters.
//
// std_stable_sort(xs, b, n) { a, c => less(a, c) } sorts xs[b .. b+n); the block is `__comp(a, c)`.
// The temporary buffer always gets its requested size ((n + 1) / 2), as it does on any real host.
import std;

fn std_stable_sort<T, F>(xs: T[>..<]&, b: i64, n: i64) {
    if n <= 0 { return; }
    var buf: T[>..<] = [];
    let half = (n + 1) / 2;
    // __stable_sort_adaptive(first, first + half, last, buffer)
    stds_merge_sort_with_buffer(xs, b, b + half, buf, F);
    stds_merge_sort_with_buffer(xs, b + half, b + n, buf, F);
    stds_merge_adaptive(xs, b, b + half, b + n, half, n - half, buf, F);
}

fn stds_insertion_sort<T, F>(xs: T[>..<]&, first: i64, last: i64) {
    if first == last { return; }
    var i = first + 1;
    while i != last {
        let v = xs[i];
        if F(v, xs[first]) {
            var k = i;
            while k > first { xs[k] = xs[k - 1]; k--; }
            xs[first] = v;
        } else {
            // __unguarded_linear_insert
            var l = i;
            var nx = i - 1;
            while F(v, xs[nx]) { xs[l] = xs[nx]; l = nx; nx--; }
            xs[l] = v;
        }
        i++;
    }
}

fn stds_merge_sort_with_buffer<T, F>(xs: T[>..<]&, first: i64, last: i64, buf: T[>..<]&) {
    let len = last - first;
    // __chunk_insertion_sort(first, last, 7)
    var f = first;
    while last - f >= 7 { stds_insertion_sort(xs, f, f + 7, F); f += 7; }
    stds_insertion_sort(xs, f, last, F);
    buf.clear();
    for k in len { buf.push(xs[first + k]); }
    var step: i64 = 7;
    while step < len {
        // __merge_loop(first, last, buffer, step)
        stds_merge_loop(xs, first, last, buf, 0, step, F);
        step *= 2;
        // __merge_loop(buffer, buffer_last, first, step)
        stds_merge_loop(buf, 0, len, xs, first, step, F);
        step *= 2;
    }
}

// __merge_loop(src[first..last) -> dst from `out`, merging runs of `step`)
fn stds_merge_loop<T, F>(src: T[>..<]&, first0: i64, last: i64, dst: T[>..<]&, out0: i64, step0: i64) {
    var first = first0;
    var out = out0;
    let two = 2 * step0;
    while last - first >= two {
        out = stds_move_merge(src, first, first + step0, first + step0, first + two, dst, out, F);
        first += two;
    }
    var step = step0;
    if last - first < step { step = last - first; }
    stds_move_merge(src, first, first + step, first + step, last, dst, out, F);
}

// __move_merge: returns the end of the output
fn stds_move_merge<T, F>(src: T[>..<]&, f1_0: i64, l1: i64, f2_0: i64, l2: i64, dst: T[>..<]&, out0: i64) -> i64 {
    var f1 = f1_0;
    var f2 = f2_0;
    var out = out0;
    while f1 != l1 && f2 != l2 {
        if F(src[f2], src[f1]) { dst[out] = src[f2]; f2++; } else { dst[out] = src[f1]; f1++; }
        out++;
    }
    while f1 != l1 { dst[out] = src[f1]; f1++; out++; }
    while f2 != l2 { dst[out] = src[f2]; f2++; out++; }
    return out;
}

// __merge_adaptive with a buffer large enough for the smaller half
fn stds_merge_adaptive<T, F>(xs: T[>..<]&, first: i64, middle: i64, last: i64, len1: i64, len2: i64, buf: T[>..<]&) {
    buf.clear();
    if len1 <= len2 {
        for k in first..middle { buf.push(xs[k]); }
        // __move_merge_adaptive(buffer, buffer_end, middle, last, first)
        var b1: i64 = 0;
        let e1 = buf.len;
        var f2 = middle;
        var out = first;
        while b1 != e1 && f2 != last {
            if F(xs[f2], buf[b1]) { xs[out] = xs[f2]; f2++; } else { xs[out] = buf[b1]; b1++; }
            out++;
        }
        while b1 != e1 { xs[out] = buf[b1]; b1++; out++; }
    } else {
        for k in middle..last { buf.push(xs[k]); }
        // __move_merge_adaptive_backward(first, middle, buffer, buffer_end, last)
        if first == middle {
            var r = last;
            var k = buf.len;
            while k > 0 { k--; r--; xs[r] = buf[k]; }
            return;
        }
        if buf.len == 0 { return; }
        var l1 = middle - 1;
        var l2 = buf.len - 1;
        var r = last;
        loop {
            if F(buf[l2], xs[l1]) {
                r--;
                xs[r] = xs[l1];
                if first == l1 {
                    // move_backward(buffer, ++last2, result)
                    var k = l2 + 1;
                    while k > 0 { k--; r--; xs[r] = buf[k]; }
                    return;
                }
                l1--;
            } else {
                r--;
                xs[r] = buf[l2];
                if l2 == 0 { return; }
                l2--;
            }
        }
    }
}

// std::sort (GCC 12 libstdc++: __introsort_loop with __unguarded_partition_pivot / __move_median_to_first,
// the heap fallback at the depth limit, then __final_insertion_sort) on xs[b .. b+n)
fn std_sort<T, F>(xs: T[>..<]&, b: i64, n: i64) {
    if n <= 1 { return; }
    var lg: i64 = 0;
    while (1 << (lg + 1)) <= n { lg++; }
    stds_introsort_loop(xs, b, b + n, lg * 2, F);
    // __final_insertion_sort
    if n > 16 {
        stds_insertion_sort(xs, b, b + 16, F);
        var i = b + 16;
        while i != b + n {
            // __unguarded_linear_insert
            let v = xs[i];
            var l = i;
            var nx = i - 1;
            while F(v, xs[nx]) { xs[l] = xs[nx]; l = nx; nx--; }
            xs[l] = v;
            i++;
        }
    } else {
        stds_insertion_sort(xs, b, b + n, F);
    }
}

recursive fn stds_introsort_loop<T, F>(xs: T[>..<]&, first: i64, last0: i64, depth0: i64) {
    var last = last0;
    var depth = depth0;
    while last - first > 16 {
        if depth == 0 {
            // __partial_sort(first, last, last): __heap_select + __sort_heap
            stds_make_heap(xs, first, last, F);
            var e = last;
            while e - first > 1 {
                e--;
                // __pop_heap(first, e, e)
                let v = xs[e];
                xs[e] = xs[first];
                stds_adjust_heap(xs, first, 0, e - first, v, F);
            }
            return;
        }
        depth--;
        // __unguarded_partition_pivot
        let mid = first + (last - first) / 2;
        stds_move_median_to_first(xs, first, first + 1, mid, last - 1, F);
        var lo = first + 1;
        var hi = last;
        loop {
            while F(xs[lo], xs[first]) { lo++; }
            hi--;
            while F(xs[first], xs[hi]) { hi--; }
            if !(lo < hi) { break; }
            let t = xs[lo]; xs[lo] = xs[hi]; xs[hi] = t;
            lo++;
        }
        let cut = lo;
        stds_introsort_loop(xs, cut, last, depth, F);
        last = cut;
    }
}

fn stds_move_median_to_first<T, F>(xs: T[>..<]&, r: i64, a: i64, b: i64, c: i64) {
    var m = b;
    if F(xs[a], xs[b]) {
        if F(xs[b], xs[c]) { m = b; } else if F(xs[a], xs[c]) { m = c; } else { m = a; }
    } else if F(xs[a], xs[c]) { m = a; }
    else if F(xs[b], xs[c]) { m = c; }
    else { m = b; }
    let t = xs[r]; xs[r] = xs[m]; xs[m] = t;
}

fn stds_adjust_heap<T, F>(xs: T[>..<]&, first: i64, hole0: i64, len: i64, v: T) {
    var hole = hole0;
    let top = hole0;
    var second = hole0;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if F(xs[first + second], xs[first + second - 1]) { second--; }
        xs[first + hole] = xs[first + second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        xs[first + hole] = xs[first + second - 1];
        hole = second - 1;
    }
    // __push_heap
    var parent = (hole - 1) / 2;
    while hole > top && F(xs[first + parent], v) {
        xs[first + hole] = xs[first + parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    xs[first + hole] = v;
}

fn stds_make_heap<T, F>(xs: T[>..<]&, first: i64, last: i64) {
    let len = last - first;
    if len < 2 { return; }
    var parent = (len - 2) / 2;
    loop {
        let v = xs[first + parent];
        stds_adjust_heap(xs, first, parent, len, v, F);
        if parent == 0 { return; }
        parent--;
    }
}
