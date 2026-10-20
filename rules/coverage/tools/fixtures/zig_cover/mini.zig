//! The code under test of zig_cover_exe_test.zig: three arms of one function, and a function no test calls.
pub fn classify(n: i32) []const u8 {
    if (n < 0) {
        return "negative";
    }
    if (n == 0) {
        return "zero";
    }
    return "positive";
}

// Nothing refers to this function, so the compiler never analyses it and the executable holds no code for it.
pub fn never_called(n: i32) i32 {
    return n + 1;
}
