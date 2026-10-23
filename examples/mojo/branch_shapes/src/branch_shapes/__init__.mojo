"""branch_shapes: three constructs the branch classifier must read without refusing them, and without counting a decision that is not one. See each function."""

from std.sys import CompilationTarget


struct Stamp:
    var is_dst: Bool

    def __init__(out self, is_dst: Bool):
        self.is_dst = is_dst


def dst_flag(t: Stamp) -> String:
    # A Bool converted to an Int: the compiler writes it as a select between 0 and 1 at the `Int(`. The source has no decision here.
    return String(Int(t.is_dst))


def compress[N: Int](vec: SIMD[DType.uint32, N], mask: SIMD[DType.bool, N], mut out: List[UInt32]) -> Int:
    # One `if` per lane, in a loop the compiler unrolls: N copies of the `if` in one function, and a different N in each instance. They are one
    # decision (one pair of arms, the lanes' counts summed).
    var c = 0
    comptime for k in range(N):
        if mask[k]:
            out[c] = vec[k]
            c = c + 1
    return c


def x86_linux() -> Bool:
    # Neither operand is known to the optimizer, yet both are constants of the build: Mojo keeps the call of each target query and branches on the
    # first one's result. No decision at run time, so no branch to cover.
    return CompilationTarget.is_x86() and CompilationTarget.is_linux()
