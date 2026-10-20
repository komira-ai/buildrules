"""`isa_audit`: disassemble a binary with the pinned llvm-objdump and compare what it contains with the ISA level it was built for.

A flag that never reached the compiler leaves a build that is green, cached and wrong: the v3 platform compiles baseline code,
or a v1 build quietly uses AVX2 and dies with SIGILL on an older worker. This action reads the machine code instead of the argv.

`expect = "avx2"`: the binary must contain 256-bit (`ymm`) instructions, which no x86-64-v1 or v2 build emits.
`expect = "none"`:  it must contain none.
The action writes a report (counts of instructions per register class, the first ymm lines) and fails on a mismatch.
`expect` comes from the target platform: `expected_vector_width()` in rules/isa.bzl.
"""

load(":providers.bzl", "RustToolchainInfo")

_TRIPLE = "x86_64-unknown-linux-gnu"

_AUDIT = """set -eu
BB="$1"; TOOLS="$2"; BIN="$3"; OUT="$4"; EXPECT="$5"; LABEL="$6"
OBJDUMP="$TOOLS/lib/rustlib/$TRIPLE/bin/llvm-objdump"
"$OBJDUMP" -d --no-show-raw-insn "$BIN" > "$OUT.asm"
YMM=$("$BB" grep -c ymm "$OUT.asm" || true)
XMM=$("$BB" grep -c xmm "$OUT.asm" || true)
VPADD=$("$BB" grep -c 'vpaddd.*ymm' "$OUT.asm" || true)
INSNS=$("$BB" grep -c '^ *[0-9a-f]*:' "$OUT.asm" || true)
{
    echo "target: $LABEL"
    echo "expect: $EXPECT"
    echo "instructions: $INSNS"
    echo "instructions naming ymm (AVX2 width): $YMM"
    echo "instructions naming xmm (SSE width): $XMM"
    echo "vpaddd on ymm (the vectorized sum, AVX2-only): $VPADD"
    echo "first ymm lines:"
    "$BB" grep ymm "$OUT.asm" | "$BB" head -5 || true
} > "$OUT"
case "$EXPECT" in
    avx2)
        if [ "$YMM" -eq 0 ]; then
            echo "isa_audit: $LABEL was built for a level with AVX2 but its machine code has no ymm instruction: the ISA flags never reached the compiler" >&2
            exit 1
        fi
        ;;
    none)
        if [ "$YMM" -ne 0 ]; then
            echo "isa_audit: $LABEL was built for a level without AVX2 but $YMM instructions name ymm: it would die with SIGILL on a baseline worker" >&2
            "$BB" grep ymm "$OUT.asm" | "$BB" head -5 >&2 || true
            exit 1
        fi
        ;;
    *)
        echo "isa_audit: expect must be avx2 or none, got '$EXPECT'" >&2
        exit 2
        ;;
esac
"""

def _impl(ctx):
    tc = ctx.attrs._toolchain[RustToolchainInfo]
    tools = ctx.attrs._llvm_tools[DefaultInfo].default_outputs[0]
    binary = ctx.attrs.binary[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".report")
    ctx.actions.run(
        cmd_args(
            tc.busybox,
            "sh",
            "-c",
            _AUDIT,
            "sh",
            tc.busybox,
            tools,
            binary,
            out.as_output(),
            ctx.attrs.expect,
            str(ctx.attrs.binary.label.raw_target()),
            hidden = [],
        ),
        category = "isa_audit",
        identifier = ctx.label.name,
        env = {"TRIPLE": _TRIPLE},
    )
    return [DefaultInfo(default_output = out)]

isa_audit = rule(
    impl = _impl,
    attrs = {
        "binary": attrs.dep(),
        "expect": attrs.string(),
        "_llvm_tools": attrs.exec_dep(default = "toolchains//:llvm_tools"),
        "_toolchain": attrs.exec_dep(default = "toolchains//:rust", providers = [RustToolchainInfo]),
    },
)
