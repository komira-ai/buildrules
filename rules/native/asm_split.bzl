"""`asm_split`: assembly that is preprocessed, has its `;` turned into line breaks, and is assembled as assembly (native_library, rules/native/defs.bzl).

A `.S` file of a library such as s2n-bignum builds its routines out of macros whose instructions are joined with `;`. The assembler of Mach-O arm64 reads `;` as the start of a
comment, so each macro keeps its first instruction: the file assembles, and the routine computes the wrong thing with no error. aws-lc's CMake pipes `cc -E` through `tr ';' '\\n'`
(`s2n_asm_cpreprocess`); this does the same with the toolchain's own compiler, so it follows whatever C/C++ toolchain the repository uses:

    for each named source:   <compiler> <the toolchain's flags> <the library's flags> -I <headers> -E -x assembler-with-cpp <source>   ->  asm_split  ->  <name>.s

and the library's `cxx_library` assembles the `.s` files with its assembly flags, as it assembles any `.s`. The flags are the ones of the real compile that the preprocessor reads:
the toolchain's target and CPU, the library's `asm_flags`, `-I` of the include directories of its upstream tree and of its dependencies' `exported_includes`, the `-include` of the
prefix header, and `-I` of the library's own `hdrs`, staged under their include names. A header a dependency exports with `exported_headers` is not among them.
"""

load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")
load("//rules/cxx:providers.bzl", "NativeLibraryInfo")

def split_name(src):
    """The name of the `.s` file made of the source `src` (a path): the path with its `/` replaced, so two sources of one file name stay two files."""
    return src.replace("/", "__") + ".s"

def _impl(ctx):
    cxx = ctx.attrs._cxx[CxxToolchainInfo]
    as_info = cxx.as_compiler_info
    hdr_dir = ctx.actions.copied_dir("hdrs", {name: f for name, f in ctx.attrs.hdrs.items()})
    include_dirs = []
    for d in ctx.attrs.deps:
        include_dirs.extend(d[NativeLibraryInfo].include_dirs)
    outs = {}
    for src, name in zip(ctx.attrs.srcs, ctx.attrs.names):
        out = ctx.actions.declare_output(name)
        cmd = cmd_args(
            ctx.attrs._tool[RunInfo],
            "--out",
            out.as_output(),
            "--",
            as_info.compiler,
            as_info.compiler_flags,
            as_info.preprocessor_flags,
            ctx.attrs.flags,
            "-I",
            hdr_dir,
            [cmd_args("-I", d) for d in include_dirs],
            "-E",
            "-x",
            "assembler-with-cpp",
            src,
        )
        ctx.actions.run(cmd, category = "asm_split", identifier = name)
        outs[name] = out
    return [DefaultInfo(
        default_outputs = list(outs.values()),
        sub_targets = {name: [DefaultInfo(default_output = out)] for name, out in outs.items()},
    )]

asm_split_rule = rule(
    impl = _impl,
    doc = "The `.s` file of each source of `srcs`: preprocessed with `flags`, the toolchain's flags and the headers, with every `;` of the text a line break (rules/cxx/asm_split.zig). `[<name>]` is one file.",
    attrs = {
        # Libraries whose `exported_includes` the preprocessor reads.
        "deps": attrs.list(attrs.dep(providers = [NativeLibraryInfo]), default = []),
        "flags": attrs.list(attrs.arg(), default = []),
        # The library's own private headers, by the name they are included by.
        "hdrs": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # One file name for each source, in the same order (`split_name`).
        "names": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "_cxx": attrs.toolchain_dep(default = "toolchains//:cxx", providers = [CxxToolchainInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:asm_split", providers = [RunInfo]),
    },
)
