"""Symbol prefixing of vendored C libraries, and the small rules around them (rules/cxx/README.md).

`prefix_header` writes the header that renames every global symbol of a C
library, read from the library's unprefixed archive with `elfsyms`.
`prefixed_archive_check` reads the prefixed archive back and fails its build
action unless every symbol it defines carries the prefix; its result is a
`ValidationInfo`. Both actions run `prefix_tool` (Zig, prefix/src), which runs
`elfsyms`; neither runs a shell. `checked_cxx_library` is the library as other
targets use it: the providers of the prefixed `cxx_library`, with the checks
as dependencies, so Buck2 runs them in every build whose graph holds the
library. `c_exe` builds `elfsyms` itself: one C file, compiled and linked
static (musl) with the pinned zig. `c_check` runs a built executable on the
execution platform and fails unless it exits 0 and prints exactly what is
expected (a self-check binary, as a validation). `staged_files` copies sources
under buck-out.

`c_exe` runs under the pinned busybox, and the source it compiles is copied
under buck-out first: a source file's path differs between a standalone
checkout and a repository mounting buildrules as a cell, and so would the
action's digest.
"""


_BUSYBOX = "buildrules//rules/pins:busybox"

def _staged(ctx, src):
    return ctx.actions.copy_file("_staged/" + src.short_path, src)

def _c_exe_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name)
    script = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.buildrules_c_exe" ;;
    /*) T="$BUCK_SCRATCH_PATH/c_exe" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/c_exe" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/zig-global" "$T/zig-local" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" cc -target x86_64-linux-musl -O2 -static -Wall -Werror "$2" -o "$3"
rm -rf "$T"
"""
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", script, "sh", bb, zig, _staged(ctx, ctx.attrs.src), out.as_output()),
        category = "c_exe",
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

_c_exe = rule(
    impl = _c_exe_impl,
    doc = "One C file built into a static x86_64 Linux (musl) executable with the pinned zig.",
    attrs = {
        "busybox": attrs.dep(default = _BUSYBOX),
        "src": attrs.source(),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
    },
)

c_exe = _c_exe

def _c_shared_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.attrs.soname)
    script = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.buildrules_c_shared" ;;
    /*) T="$BUCK_SCRATCH_PATH/c_shared" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/c_shared" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/zig-global" "$T/zig-local" "$T/home"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; ZIG_GLOBAL_CACHE_DIR="$T/zig-global"; ZIG_LOCAL_CACHE_DIR="$T/zig-local"; HOME="$T/home"
export PATH ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR HOME
"$1/zig" cc -target "$4" -O2 -g0 -fPIC -shared -Wall -Werror "-Wl,-soname,$5" -Wl,--build-id=none "$2" -o "$3"
rm -rf "$T"
"""
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", script, "sh", bb, zig, _staged(ctx, ctx.attrs.src), out.as_output(), ctx.attrs.target, ctx.attrs.soname),
        category = "c_shared",
    )
    return [DefaultInfo(default_output = out)]

_c_shared = rule(
    impl = _c_shared_impl,
    doc = "One C file built into a shared library (glibc target) with the pinned zig: the native library of a Mojo package.",
    attrs = {
        "busybox": attrs.dep(default = _BUSYBOX),
        "soname": attrs.string(),
        "src": attrs.source(),
        # zig's -target: the glibc floor of the Mojo toolchain (mopm's graph names the same triple as `cc_target`).
        "target": attrs.string(default = "x86_64-linux-gnu.2.34"),
        "zig": attrs.dep(default = "buildrules//rules/pins:zig"),
    },
)

c_shared = _c_shared

def _prefix_header_impl(ctx):
    hdr = ctx.actions.declare_output(ctx.attrs.header)
    syms = ctx.actions.declare_output("symbols.txt")
    more = ["--strip", ctx.attrs.strip] if ctx.attrs.strip else []
    for name in ctx.attrs.extra_symbols:
        more.extend(["--extra", name])
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "header",
        "--elfsyms",
        ctx.attrs._elfsyms[RunInfo],
        "--archive",
        ctx.attrs.archive,
        "--header",
        hdr.as_output(),
        "--symbols",
        syms.as_output(),
        "--style",
        ctx.attrs.style,
        "--prefix",
        ctx.attrs.prefix,
        "--min",
        str(ctx.attrs.min_symbols),
        more,
    )
    ctx.actions.run(cmd, category = "prefix_header")
    return [DefaultInfo(default_output = hdr, sub_targets = {"symbols": [DefaultInfo(default_output = syms)]})]

_prefix_header = rule(
    impl = _prefix_header_impl,
    doc = "The header renaming every defined global symbol of `archive` (an unprefixed build of the library), plus `extra_symbols`, to its prefixed name; `[symbols]` is the list of the original names, one per line. `prefix_tool header` writes it (src/prefix.zig says what each `style` writes).",
    attrs = {
        "archive": attrs.source(doc = "The unprefixed static archive whose symbol table names what to rename."),
        "extra_symbols": attrs.list(attrs.string(), default = [], doc = "Names the library references but does not define (a weak hook a program may define), renamed too."),
        "header": attrs.string(default = "prefix_symbols.h", doc = "The output's file name."),
        "min_symbols": attrs.int(doc = "Fewer names than this fails the action: the archive was not the library."),
        "prefix": attrs.string(),
        "strip": attrs.string(default = "", doc = "style strip: the library's own prefix, replaced by `prefix`."),
        "style": attrs.enum(["boringssl", "strip"]),
        "_elfsyms": attrs.exec_dep(default = "buildrules//rules/cxx:elfsyms", providers = [RunInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:prefix_tool", providers = [RunInfo]),
    },
)

prefix_header = _prefix_header

def _check_impl(ctx):
    result = ctx.actions.declare_output("validation.json")
    more = []
    for pattern in ctx.attrs.allow:
        more.extend(["--allow", pattern])
    for names in ctx.attrs.original_names:
        more.extend(["--names", names])
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "check",
        "--elfsyms",
        ctx.attrs._elfsyms[RunInfo],
        "--archive",
        ctx.attrs.archive,
        "--result",
        result.as_output(),
        "--prefix",
        ctx.attrs.prefix,
        "--min",
        str(ctx.attrs.min_defined),
        more,
    )
    ctx.actions.run(cmd, category = "prefixed_archive_check", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

_prefixed_archive_check = rule(
    impl = _check_impl,
    doc = "Fails its build action unless every defined and every weak undefined symbol of `archive` starts with `prefix` (or matches one of `allow`), no undefined symbol is one of `original_names`, and at least `min_defined` defined symbols carry the prefix. `prefix_tool check` is the check.",
    attrs = {
        "allow": attrs.list(attrs.string(), default = [], doc = "Names that may lack the prefix: a whole symbol name, or a name's beginning followed by `*` (`_Z*`, every C++ name). Each needs a reason beside it."),
        "archive": attrs.source(doc = "The prefixed static archive."),
        "min_defined": attrs.int(),
        "original_names": attrs.list(attrs.source(), default = [], doc = "Files listing the unprefixed names, one per line (a prefix_header's `[symbols]`)."),
        "prefix": attrs.string(),
        "_elfsyms": attrs.exec_dep(default = "buildrules//rules/cxx:elfsyms", providers = [RunInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:prefix_tool", providers = [RunInfo]),
    },
)

prefixed_archive_check = _prefixed_archive_check

def _checked_impl(ctx):
    return ctx.attrs.lib.providers

_checked_cxx_library = rule(
    impl = _checked_impl,
    doc = "The C/C++ library `lib`, every provider of it unchanged, gated by `checks`: targets returning a `ValidationInfo`, which Buck2 runs in every build whose graph holds this target.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "lib": attrs.dep(),
    },
)

checked_cxx_library = _checked_cxx_library

def _staged_files_impl(ctx):
    outs = []
    sub_targets = {}
    for src in ctx.attrs.srcs:
        # Keyed by the path in the package, like a source file of the package.
        path = src.short_path
        pkg = ctx.label.package
        if pkg and path.startswith(pkg + "/"):
            path = path[len(pkg) + 1:]
        out = ctx.actions.copy_file(ctx.label.name + "/" + path, src)
        outs.append(out)
        sub_targets[path] = [DefaultInfo(default_output = out)]
    return [DefaultInfo(default_outputs = outs, sub_targets = sub_targets)]

# Source files of a C/C++ library, copied into buck-out; `:<target>[add.c]` names one. A source file is an
# input of a remote action at its path in the project, which depends on where the repository mounts the
# cell, and the compiler records that path in the object. A copy's path in buck-out names the cell, not its
# mount point, so the compile and archive actions keep one digest wherever buildrules is mounted.
staged_files = rule(
    impl = _staged_files_impl,
    attrs = {"srcs": attrs.list(attrs.source(), default = [])},
)

_CHECK_SCRIPT = """
EXE="$1"; WANT="$2"; OUT="$3"
GOT=$("$EXE") || { echo "c_check: $EXE exited non-zero" >&2; exit 1; }
if [ "$GOT" != "$WANT" ]; then
    echo "c_check: expected '$WANT' but $EXE printed '$GOT'" >&2
    exit 1
fi
echo "$GOT" > "$OUT"
"""

def _c_check_result(actions, stdout, expected, label, result):
    got = stdout.read_string()
    if got.rstrip("\n") == expected:
        status, message = "success", "c_check: {} printed its expected_stdout ({} bytes)".format(label, len(got))
    else:
        status, message = "failure", "c_check: the stdout of {} differs from its expected_stdout".format(label)
    actions.write_json(result, {"data": {"message": message, "status": status}, "version": 1})
    return []

# A validation result is one JSON file; this writes it from the recorded stdout, so it cannot exist before the
# run has passed, and says "failure" unless the stdout is the expected one (a second comparison, in Starlark).
_c_check_dynamic = dynamic_actions(
    impl = _c_check_result,
    attrs = {
        "expected": dynattrs.value(str),
        "label": dynattrs.value(str),
        "result": dynattrs.output(),
        "stdout": dynattrs.artifact_value(),
    },
)

def _c_check_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output(ctx.label.name + ".stdout")
    ctx.actions.run(
        cmd_args(bb, "sh", "-euc", _CHECK_SCRIPT, "sh", ctx.attrs.exe[RunInfo], ctx.attrs.expected_stdout, out.as_output()),
        category = "c_check",
    )
    result = ctx.actions.declare_output(ctx.label.name + ".c_check.json")
    ctx.actions.dynamic_output_new(_c_check_dynamic(
        stdout = out,
        expected = ctx.attrs.expected_stdout,
        label = str(ctx.label.raw_target()),
        result = result.as_output(),
    ))
    return [
        DefaultInfo(default_output = result, other_outputs = [out]),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

c_check = rule(
    impl = _c_check_impl,
    doc = "Runs `exe` (a cxx_binary) on the execution platform: fails unless it exits 0 and prints exactly `expected_stdout` (trailing newline ignored). A validation: a checked_cxx_library listing it is never built red.",
    attrs = {
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "exe": attrs.dep(providers = [RunInfo]),
        "expected_stdout": attrs.string(),
    },
)

def _glibc_floor_check_impl(ctx):
    result = ctx.actions.declare_output(ctx.label.name + ".glibc_floor.json")
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], ctx.attrs.exe[DefaultInfo].default_outputs[0], ctx.attrs.max, result.as_output()),
        category = "glibc_floor_check",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

glibc_floor_check = rule(
    impl = _glibc_floor_check_impl,
    doc = "Fails unless the ELF `exe` needs no glibc symbol version newer than `max` (the toolchain's target floor). A validation.",
    attrs = {
        "exe": attrs.dep(),
        "max": attrs.string(default = "2.34"),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:glibc_floor", providers = [RunInfo]),
    },
)

def _hermetic_check_impl(ctx):
    result = ctx.actions.declare_output(ctx.label.name + ".hermetic.json")
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], ctx.attrs.exe[DefaultInfo].default_outputs[0], result.as_output()),
        category = "hermetic_check",
        identifier = ctx.label.name,
    )
    return [
        DefaultInfo(default_output = result),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

hermetic_check = rule(
    impl = _hermetic_check_impl,
    doc = "Fails unless the ELF `exe` has no `.debug_*` section and does not contain the absolute path of the directory the action runs in (the exec root: the directory the binary was linked in). zig cc assembles the C runtime's start-up objects at link time with debug info that stamps the compile directory, so a binary linked without `-Wl,--strip-debug` depends on the checkout path. A validation.",
    attrs = {
        "exe": attrs.dep(),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:hermetic", providers = [RunInfo]),
    },
)
