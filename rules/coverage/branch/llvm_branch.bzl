"""The LLVM pieces of Mojo branch coverage, unpacked from pinned packages and checked (README.md).

`llvm_branch_unpack` runs `llvm_branch unpack` (llvm_branch.zig) in one build action: it writes named members of pinned `.conda` packages
into one directory, each a regular file (a member that is a symbolic link in its package is written as the file it resolves to), and
nothing else.

`llvm_branch_check` runs `llvm_branch check <mode>` in a build action and returns a `ValidationInfo`. `cov_branch_toolchain` is what the
Mojo rules take: the two directories and `CovBranchInfo`, with the checks as dependencies, so no build that uses them succeeds unless the
checks pass. Each is configured for the execution platform of the target that takes it; the checked bytes and the handed-out bytes are
one configured target because every target here has the same `exec_compatible_with` (LINUX_X86_64).
"""

CovBranchInfo = provider(
    doc = "The LLVM pieces of the branch coverage of one Mojo version (rules/coverage/branch/README.md).",
    fields = {
        "lld": provider_field(typing.Any, default = None),  # artifact: `bin/lld` of `lld_dir`, Mojo's own LLD 24
        "lld_dir": provider_field(typing.Any, default = None),  # artifact: the directory holding it and the C++ runtime it loads
        "nm": provider_field(typing.Any, default = None),  # artifact: `bin/llvm-nm` of `tools_dir`, which lists the symbols a native library defines
        "profdata": provider_field(typing.Any, default = None),  # artifact: `bin/llvm-profdata` of `tools_dir`
        "runtime": provider_field(typing.Any, default = None),  # artifact: the profile runtime, `runtime/libclang_rt.profile-x86_64.a` of `tools_dir`
        "tools_dir": provider_field(typing.Any, default = None),  # artifact: llvm-profdata, llvm-nm, their libraries and runtime/
    },
)

# The raw profile version that code Mojo's lld instruments writes and that the pinned llvm-profdata accepts (README.md, "The version
# coupling"): `raw_version_check` requires the one it measures to be this, and every branch coverage run requires each raw profile to have
# it. A new Mojo or new LLVM 23 pins that change it change this number.
RAW_PROFILE_VERSION = 11

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _unpack_impl(ctx):
    out = ctx.actions.declare_output("dist", dir = True)
    packages = [cmd_args(name, "=", _out(dep), delimiter = "") for name, dep in sorted(ctx.attrs.packages.items())]
    members = [cmd_args(dest, "=", src, delimiter = "") for dest, src in sorted(ctx.attrs.members.items())]
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "unpack",
            _out(ctx.attrs.conda_payload),
            out.as_output(),
            packages,
            "--",
            members,
        ),
        category = "llvm_branch_unpack",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

llvm_branch_unpack = rule(
    impl = _unpack_impl,
    doc = "A directory holding `members` (destination path -> `<package name>/<member path>`) of the pinned `.conda` `packages`, each a regular file, and nothing else; the program fails the action on a member that is missing or empty.",
    attrs = {
        "conda_payload": attrs.exec_dep(default = "buildrules//rules/coverage:conda_payload", doc = "The tool that writes a .conda package's payload tar."),
        "members": attrs.dict(attrs.string(), attrs.string(), doc = "destination -> `<package name>/<member>`."),
        "packages": attrs.dict(attrs.string(), attrs.dep(), doc = "package name -> pinned .conda."),
        "_tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:llvm_branch_bin", providers = [RunInfo]),
    },
)

def _check_impl(ctx):
    # Runs `llvm_branch check <mode> <zig_dir> <report_dir> <lld_dir or -> <tools_dir or -> <fixture_dir or -> want...`. One output: buck2
    # refuses a validation result whose action produces more than one. The result is copied out of the directory.
    staged = ctx.actions.copied_dir("check_srcs", {"fixtures/" + f.basename: f for f in ctx.attrs.fixtures})
    report = ctx.actions.declare_output("report", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs._tool[RunInfo],
            "check",
            ctx.attrs.mode,
            _out(ctx.attrs._zig),
            report.as_output(),
            _out(ctx.attrs.lld) if ctx.attrs.lld else "-",
            _out(ctx.attrs.tools) if ctx.attrs.tools else "-",
            staged.project("fixtures") if ctx.attrs.fixtures else "-",
            [cmd_args(k, "=", v, delimiter = "") for k, v in sorted(ctx.attrs.want.items())],
        ),
        category = "llvm_branch_" + ctx.attrs.mode,
        identifier = ctx.label.name,
    )
    result = ctx.actions.copy_file("validation.json", report.project("validation.json"))
    return [
        DefaultInfo(default_output = result, sub_targets = {"report": [DefaultInfo(default_output = report)]}),
        ValidationInfo(validations = [ValidationSpec(name = ctx.label.name, validation_result = result)]),
    ]

llvm_branch_check = rule(
    impl = _check_impl,
    doc = "Runs `llvm_branch check <mode>` (README.md, Checks) against the unpacked `lld` and `tools` directories, with `want` (key -> expected value) as its expectations. Fails the build on a wrong result; `[report]` holds what the check measured.",
    attrs = {
        "fixtures": attrs.list(attrs.source(), default = [], doc = "fixtures/: the C program the raw-version check instruments."),
        "lld": attrs.option(attrs.exec_dep(), default = None, doc = "The unpacked directory of Mojo's lld."),
        "mode": attrs.enum(["lld", "tools", "raw_version"]),
        "tools": attrs.option(attrs.exec_dep(), default = None, doc = "The unpacked directory of the LLVM 23 tools."),
        "want": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "_tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:llvm_branch_bin", providers = [RunInfo]),
        "_zig": attrs.exec_dep(default = "buildrules//rules/pins:zig"),
    },
)

def _toolchain_impl(ctx):
    lld_dir = _out(ctx.attrs.lld)
    tools_dir = _out(ctx.attrs.tools)
    return [
        DefaultInfo(default_outputs = [lld_dir, tools_dir]),
        CovBranchInfo(
            lld = lld_dir.project("bin/lld"),
            lld_dir = lld_dir,
            nm = tools_dir.project("bin/llvm-nm"),
            profdata = tools_dir.project("bin/llvm-profdata"),
            runtime = tools_dir.project("runtime/libclang_rt.profile-x86_64.a"),
            tools_dir = tools_dir,
        ),
    ]

cov_branch_toolchain = rule(
    impl = _toolchain_impl,
    doc = "The LLVM pieces of the branch coverage of one Mojo version as the Mojo rules take them (`CovBranchInfo`), gated by the validations in `checks`.",
    attrs = {
        "checks": attrs.list(attrs.dep(providers = [ValidationInfo])),
        "lld": attrs.exec_dep(),
        "tools": attrs.exec_dep(),
    },
)
