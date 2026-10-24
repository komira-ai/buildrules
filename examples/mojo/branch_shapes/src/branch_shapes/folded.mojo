"""folded: a file whose only decision-looking line is folded by the compiler, so its code holds no branch at all."""

from std.sys import CompilationTarget, simd_width_of


def wide_x86() -> Bool:
    # Every operand is a compile-time constant: folded when the module is compiled, so this file has no conditional branch, select or switch. The
    # line looks like a decision (`and`) and the IR has code on it; the file has no other decision, so zero branches are parsed from it, and that is
    # not a refusal: the line is 0/0.
    return CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16
