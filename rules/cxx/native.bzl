"""`native_archive` and `native_static`: the static library a Mojo package ships (docs/contract.md, section 12, "Native libraries").

    native_static(name = "native_shim", srcs = [...], hdrs = [...], soname = "libshim.a")

builds two targets in the calling package:

    :native_shim_cxx   the `cxx_library` of the sources, compiled by the pinned zig at the platform baseline (rules/cxx/README.md)
    :native_shim       the `native_archive` of it: `libshim.a`, behind the checks of rules/cxx/archive (archive_check)

`native_archive` takes the package's OWN `cxx_library` (`[static-pic]`; a library of another package is refused) and writes it under the library's
soname. The archive is the one the toolchain's `ar` wrote, so its bytes are the toolchain's; `archive_check` is the validation that holds them to what a
library other people link must be (deterministic headers, members in the order of their names, no debug section, no build path, nothing undefined that
the final link will lack). A build holding the target runs the check: a defect is a red build that names it.
"""

load("//rules:isa.bzl", "ISA_LEVELS", "isa_select")
load(":providers.bzl", "NativeArchiveInfo")

def _impl(ctx):
    lib = ctx.attrs.lib
    if lib.label.package != ctx.label.package or lib.label.cell != ctx.label.cell:
        fail("{}: lib is {}, a target of another package: a native library is closed over its own package's sources, and needs another package's through `needs`".format(ctx.label, lib.label))
    if len(lib[DefaultInfo].default_outputs) != 1:
        fail("{}: lib {} must be one static archive (a cxx_library's `[static-pic]` sub-target)".format(ctx.label, lib.label))
    built = lib[DefaultInfo].default_outputs[0]
    out = ctx.actions.copy_file(ctx.attrs.soname, built)
    symbols = ctx.actions.declare_output(ctx.label.name + ".symbols")
    result = ctx.actions.declare_output(ctx.label.name + ".archive_check.json")
    rest = []
    for n in ctx.attrs.needs:
        rest.extend(["--needs", n[DefaultInfo].default_outputs[0]])
    for s in ctx.attrs.allow:
        rest.extend(["--allow", s])
    ctx.actions.run(cmd_args(ctx.attrs._tool[RunInfo], out, result.as_output(), rest), category = "archive_check", identifier = ctx.label.name)

    # The list of defined symbols is its own action: a validation result is the one output of the action that writes it.
    scratch = ctx.actions.declare_output(ctx.label.name + ".listed.json")
    ctx.actions.run(cmd_args(ctx.attrs._tool[RunInfo], out, scratch.as_output(), "--symbols", symbols.as_output(), rest), category = "archive_symbols", identifier = ctx.label.name)
    info = [
        NativeArchiveInfo(soname = ctx.attrs.soname, archive = out, symbols = symbols),
    ]
    if ctx.attrs.validate:
        info.append(DefaultInfo(default_output = out, sub_targets = {"symbols": [DefaultInfo(default_output = symbols)]}))
        info.append(ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]))
    else:
        # The check as an output of the target instead of a validation: its failure is then a failed action of this target, which a bxl can count
        # (ci/planted, ci/negative.bzl); the failure of a validation ends the whole command.
        info.append(DefaultInfo(default_output = out, other_outputs = [result], sub_targets = {"symbols": [DefaultInfo(default_output = symbols)]}))
    return info

native_archive = rule(
    impl = _impl,
    doc = "The static library `soname` out of the package's own `cxx_library` `lib`, with `archive_check` as a validation. `needs` are the libraries this one calls into (their symbols may stay undefined); `allow` names symbols something the check cannot see provides.",
    attrs = {
        "allow": attrs.list(attrs.string(), default = []),
        "lib": attrs.dep(),
        "needs": attrs.list(attrs.dep(), default = []),
        "soname": attrs.string(),
        # False: the check is an output of the target and not a validation (the cases of ci/planted build it so).
        "validate": attrs.bool(default = True),
        "_tool": attrs.exec_dep(default = "buildrules//rules/cxx:archive_check", providers = [RunInfo]),
    },
)

def _same_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name + ".same")
    ctx.actions.run(
        cmd_args(ctx.attrs._check_exe[RunInfo], "same", "--out", out.as_output(), ctx.attrs.a[NativeArchiveInfo].archive, ctx.attrs.b[NativeArchiveInfo].archive),
        category = "native_same",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

native_same = rule(
    impl = _same_impl,
    doc = "Two native libraries built from the same sources at two paths are the same bytes (`check same`): a library that recorded where it was built would differ, and could not be shared through the remote cache or pinned by a sha256.",
    attrs = {
        "a": attrs.dep(providers = [NativeArchiveInfo]),
        "b": attrs.dep(providers = [NativeArchiveInfo]),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)

def _baseline():
    """The CPU flag of the platform's baseline, whatever the toolchain's default is (a v3 platform compiles the rest of the program for v3; a library other
    people link must run on any machine of the family)."""
    return isa_select(lambda l: ["-mcpu=x86_64"] if ISA_LEVELS[l]["family"] == "x86_64" else ["-mcpu=generic"], ["-mcpu=x86_64"])

def native_static(name, srcs, soname, hdrs = [], includes = [], cflags = [], cflags_by_os = {}, needs = [], allow = [], validate = True, file_prefix = None, visibility = ["PUBLIC"]):
    """A native static library: `<name>_cxx` (the `cxx_library`) and `<name>` (the `native_archive`). `includes` are directories (relative to the repository root)
    given to the compiler as `-I`; `cflags_by_os` maps `linux` and `macos` to flags added on that OS after `cflags`; `file_prefix` (default: the package
    directory) is mapped to `.` in every path the compiler records, so a copy of the sources at another path gives the same bytes."""
    if file_prefix == None:
        file_prefix = native.package_name()
    # What every native library is compiled with, before the manifest's flags (which may override it): optimised, and without the undefined-behaviour
    # instrumentation zig cc turns on when no optimisation is asked for, which records the source path and the toolchain's header paths in `.rodata`.
    defaults = ["-O2", "-fno-sanitize=undefined"]
    flags = list(cflags) + ["-I" + i for i in includes]
    for os in cflags_by_os.keys():
        if os not in ("linux", "macos"):
            fail("{}: cflags_by_os names the OS {}; the OSes are linux and macos".format(name, os))
    by_os = select({
        "buildrules//platforms:linux": list(cflags_by_os.get("linux", [])),
        "buildrules//platforms:macos": list(cflags_by_os.get("macos", [])),
        "DEFAULT": [],
    })
    prefix = ["-ffile-prefix-map={}=.".format(file_prefix)] if file_prefix else []
    native.cxx_library(
        name = name + "_cxx",
        srcs = sorted(srcs),
        headers = sorted(hdrs),
        compiler_flags = defaults + prefix + _baseline() + flags + by_os,
        preferred_linkage = "static",
        visibility = visibility,
    )
    native_archive(
        name = name,
        lib = ":" + name + "_cxx[static-pic]",
        soname = soname,
        needs = needs,
        allow = allow,
        validate = validate,
        visibility = visibility,
    )
