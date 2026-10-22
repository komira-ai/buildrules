"""The Mojo unit rules: one action per unit of mopm's unit graph (docs/contract.md, section 12).

mopm owns what "build Mojo" means. `mopm unit build` is the one compile entry: offline, no resolve, it checks every input the
graph declares (sources and natives by sha256, each dependency's `.mojoc`, the toolchain's closure hash) and then executes
`<toolchain>/mojo_compile` with an empty environment. This file only places the inputs where mopm wants them:

    --graph      the unit and its transitive dependencies, cut from the committed graph (the key of the action follows)
    --src        the unit's sources, at the paths the graph names
    --deps       `<package>.mojoc` of every unit in the closure, flat: the outputs of the dependency targets
    --natives    the native libraries by soname (built by buildrules, checked by mopm against the graph's sha256)
    --toolchain  `mojo_compile` (mojo_launch.zig), the wrapper, the compiler closure, the zig, CLOSURE_SHA256, toolchain.cfg

A unit's output directory is the action's single output. A library's `.mojoc` is `out/<package>.mojoc`; a test or binary is
`out/<name>` with its native libraries in `out/lib/`.
"""

load("//rules:isa.bzl", "isa_satisfies")
load("//rules/rust:providers.bzl", "ExecIsaInfo")
load(":providers.bzl", "MojoExeInfo", "MojoLibInfo", "MojoTestRunInfo", "MojoToolchainInfo")

# `-c buildrules.unit_nonce=N` changes every unit action's key without changing any input the compiler sees: the compile
# really re-executes, so two builds can be compared byte for byte.
_NONCE = read_config("buildrules", "unit_nonce", "")

def _file(dep):
    return dep[DefaultInfo].default_outputs[0]

# The package's `:check` (rules/mojo/check.bzl) as the validation of a step: a build of the step is red if the table is stale.
_CHECK_ATTR = attrs.option(attrs.dep(), default = None)

def _validated(ctx, info):
    if ctx.attrs.check:
        info.append(ValidationInfo(validations = [
            ValidationSpec(name = "mojo_table_in_sync", validation_result = _file(ctx.attrs.check)),
        ]))
    return info

def _unit_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    if tc.version != ctx.attrs.mojo:
        fail("{}: the graph is for Mojo {} but the toolchain {} is Mojo {}".format(ctx.label, ctx.attrs.mojo, ctx.attrs.toolchain.label, tc.version))

    # The sources, at the paths the graph names (relative to the package directory).
    srcs = {}
    for s in ctx.attrs.srcs:
        rel = s.short_path
        if ctx.attrs.src_root:
            if not rel.startswith(ctx.attrs.src_root + "/"):
                fail("{}: source {} is not under {}".format(ctx.label, s, ctx.attrs.src_root))
            rel = rel[len(ctx.attrs.src_root) + 1:]
        srcs[rel] = s
    for want in ctx.attrs.src_paths:
        if want not in srcs:
            fail("{}: the graph names the source {} but the target's `srcs` do not include it".format(ctx.label, want))
    src_dir = ctx.actions.copied_dir("src", srcs)

    # The dependencies' `.mojoc`, flat, and a check that the targets give exactly the closure the graph has.
    closure = {}
    for d in ctx.attrs.deps:
        closure.update(d[MojoLibInfo].closure)
    if sorted(closure.keys()) != sorted(ctx.attrs.closure_names):
        fail("{}: the graph's closure of {} is {} but the dependency targets give {}".format(ctx.label, ctx.attrs.unit_id, sorted(ctx.attrs.closure_names), sorted(closure.keys())))

    # The native libraries by soname.
    natives = {}
    for soname in ctx.attrs.native_sonames:
        if soname not in ctx.attrs.natives:
            fail("{}: the graph needs the native library {} but `natives` does not provide it".format(ctx.label, soname))
        natives[soname] = _file(ctx.attrs.natives[soname])

    # The toolchain directory mopm is given. mojo_compile (mojo_launch.zig) tells the wrapper where the closure and the zig are.
    cfg = "wrapper=wrapper\ncompiler=compiler\nzig=zig\ncc_target={}\n".format(tc.cc_target)
    for a in ctx.attrs.build_args:
        cfg += "build_arg={}\n".format(a)
    zig = _file(ctx.attrs.zig_override) if ctx.attrs.zig_override else tc.zig
    tc_dir = ctx.actions.copied_dir("toolchain", {
        "CLOSURE_SHA256": ctx.actions.write("CLOSURE_SHA256", tc.closure_sha256 + "\n"),
        "compiler": tc.compiler,
        "mojo_compile": _file(ctx.attrs.launcher),
        "toolchain.cfg": ctx.actions.write("toolchain.cfg", cfg),
        "wrapper": _file(ctx.attrs.wrapper),
        "zig": zig,
    })

    graph = ctx.actions.write("graph.json", ctx.attrs.graph)
    out = ctx.actions.declare_output("out", dir = True)
    cmd = cmd_args(
        ctx.attrs.mopm[RunInfo],
        "unit",
        "build",
        "--unit",
        ctx.attrs.unit_id,
        "--graph",
        graph,
        "--out",
        out.as_output(),
        "--toolchain",
        tc_dir,
        "--src",
        src_dir,
    )
    if closure:
        cmd.add("--deps", ctx.actions.copied_dir("deps", {name + ".mojoc": art for name, art in closure.items()}))
    if natives:
        cmd.add("--natives", ctx.actions.copied_dir("natives", natives))
    ctx.actions.run(
        cmd,
        category = "mojo_unit",
        identifier = ctx.attrs.unit_id,
        env = {"BUILDRULES_UNIT_NONCE": _NONCE},
    )

    if ctx.attrs.kind == "lib":
        mojoc = out.project(ctx.attrs.product)
        closure[ctx.attrs.package] = mojoc
        return _validated(ctx, [
            DefaultInfo(default_output = mojoc),
            MojoLibInfo(id = ctx.attrs.unit_id, mojoc = mojoc, closure = closure),
        ])
    return _validated(ctx, [
        DefaultInfo(default_output = out.project(ctx.attrs.product), sub_targets = {"dir": [DefaultInfo(default_output = out)]}),
        MojoExeInfo(id = ctx.attrs.unit_id, dir = out, exe = out.project(ctx.attrs.product), name = ctx.attrs.product),
    ])

mojo_unit_rule = rule(
    impl = _unit_impl,
    attrs = {
        "check": _CHECK_ATTR,
        # Direct dependencies (MojoLibInfo): the targets of the units this one imports.
        "deps": attrs.list(attrs.dep(providers = [MojoLibInfo]), default = []),
        # The unit and its transitive dependencies, as the JSON graph `mopm unit build --graph` reads.
        "graph": attrs.string(),
        "kind": attrs.string(),
        "launcher": attrs.exec_dep(default = "buildrules//rules/mojo:mojo_launch"),
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(),
        "native_sonames": attrs.list(attrs.string(), default = []),
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # Arguments mojo_launch puts right after `build` (the ISA flags of a test or binary).
        "build_args": attrs.list(attrs.string(), default = []),
        "closure_names": attrs.list(attrs.string(), default = []),
        "package": attrs.string(),
        # The file name of the product inside the output directory: `<package>.mojoc` or the executable's name.
        "product": attrs.string(),
        # Paths the graph names for this unit's sources, and the directory of the BUCK file's package they are relative to.
        "src_paths": attrs.list(attrs.string(), default = []),
        "src_root": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source(), default = []),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "unit_id": attrs.string(),
        "wrapper": attrs.exec_dep(default = "buildrules//rules/mojo:mojo_compile"),
        # Another zig directory for the link (a coverage build's cov_link keeps debug info and relocates paths).
        "zig_override": attrs.option(attrs.exec_dep(), default = None),
    },
)

def _prebuilt_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.package + ".mojoc")
    cmd = cmd_args(_file(ctx.attrs.unpacker), _file(ctx.attrs.archive), ctx.attrs.package, out.as_output())
    sub_targets = {}
    if ctx.attrs.natives:
        # The package's static native libraries (`lib/<soname>` in the `.conda`), each hashed against the lock's value before anything is written.
        # One directory, flat by soname; every soname is a sub-target (`:prebuilt_<package>[<soname>]`) that a unit's `natives` takes.
        natives = ctx.actions.declare_output("natives", dir = True)
        cmd.add("--natives", natives.as_output())
        for soname, sha256 in ctx.attrs.natives.items():
            cmd.add("--native", "{}={}".format(soname, sha256))
            sub_targets[soname] = [DefaultInfo(default_output = natives.project(soname))]
    ctx.actions.run(cmd, category = "mojo_prebuilt", identifier = ctx.attrs.unit_id)
    closure = {}
    for d in ctx.attrs.deps:
        closure.update(d[MojoLibInfo].closure)
    closure[ctx.attrs.package] = out
    return [DefaultInfo(default_output = out, sub_targets = sub_targets), MojoLibInfo(id = ctx.attrs.unit_id, mojoc = out, closure = closure)]

# A registry dependency: the `.mojoc` inside the sha256-pinned `.conda` the graph names, never compiled, and the static native libraries
# the lock pins for the package (`natives`: soname -> sha256, in the graph's order), which come out of the same file.
mojo_prebuilt_rule = rule(
    impl = _prebuilt_impl,
    attrs = {
        "archive": attrs.dep(),
        "deps": attrs.list(attrs.dep(providers = [MojoLibInfo]), default = []),
        "natives": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "package": attrs.string(),
        "unit_id": attrs.string(),
        "unpacker": attrs.exec_dep(default = "buildrules//rules/mojo:prebuilt_unpack"),
    },
)

# The binary needs the compiler's runtime libraries (libKGENCompilerRTShared.so) next to its own: the closure's lib/ is on
# LD_LIBRARY_PATH, nothing else is in the environment. Its native libraries are found through its runpath ($ORIGIN/lib).
_RUN = """set -eu
EXE="$1"; MARK="$2"; CC="$3"
case "$EXE" in /*) ;; *) EXE="$PWD/$EXE" ;; esac
case "$MARK" in /*) ;; *) MARK="$PWD/$MARK" ;; esac
case "$CC" in /*) ;; *) CC="$PWD/$CC" ;; esac
LD_LIBRARY_PATH="$CC/lib"; export LD_LIBRARY_PATH
"$EXE"
echo passed > "$MARK"
"""

def _test_run_impl(ctx):
    info = ctx.attrs.bin[MojoExeInfo]
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}. A test at an ISA level must run on a platform " +
              "that has it: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), which the mojo_package " +
              "macro does, so the farm schedules the run on a worker of at least that level.").format(ctx.label, want, have))
    bb = _file(ctx.attrs.busybox)
    compiler = ctx.attrs.toolchain[MojoToolchainInfo].compiler
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _RUN, "sh", info.exe, marker.as_output(), compiler, hidden = [info.dir]),
        category = ctx.attrs.category,
        identifier = ctx.label.name,
        env = {"BUILDRULES_UNIT_NONCE": _NONCE},
    )
    return _validated(ctx, [
        DefaultInfo(default_output = marker),
        MojoTestRunInfo(marker = marker),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [cmd_args(bb, "sh", "-c", _RUN, "sh", info.exe, "/dev/null", compiler, hidden = [info.dir])],
            labels = ["test", "mojo"],
        ),
    ])

mojo_test_run_rule = rule(
    impl = _test_run_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "bin": attrs.dep(providers = [MojoExeInfo]),
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "category": attrs.string(default = "mojo_test"),
        "required_isa": attrs.string(default = ""),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    },
)

def _gated_lib_impl(ctx):
    lib = ctx.attrs.lib[MojoLibInfo]
    markers = [t[MojoTestRunInfo].marker for t in ctx.attrs.test_runs]

    # The public `.mojoc` is a copy of the compiled one made by an action that has every test run's marker among its inputs.
    # A marker exists only when its test passed, so when any test fails this action never runs and the file does not exist: no
    # target that imports the library (it reads this file) and no `buck2 build` of the library can succeed.
    out = ctx.actions.declare_output(ctx.attrs.package + ".mojoc")
    ctx.actions.run(
        cmd_args(_file(ctx.attrs.busybox), "cp", lib.mojoc, out.as_output(), hidden = markers),
        category = "mojo_gate",
        identifier = ctx.label.name,
    )
    closure = dict(lib.closure)
    closure[ctx.attrs.package] = out
    return _validated(ctx, [
        DefaultInfo(default_output = out),
        MojoLibInfo(id = lib.id, mojoc = out, closure = closure),
    ])

# The library as the world sees it (`:lib`): the compiled library (`:lib_ungated`, which the package's own tests import) behind the
# runs of all of its tests. Same bytes as the compiled `.mojoc`, so a dependent's cache key moves only when the library does.
mojo_gated_lib_rule = rule(
    impl = _gated_lib_impl,
    attrs = {
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "check": _CHECK_ATTR,
        "lib": attrs.dep(providers = [MojoLibInfo]),
        "package": attrs.string(),
        "test_runs": attrs.list(attrs.dep(providers = [MojoTestRunInfo]), default = []),
    },
)

def _cov_run_impl(ctx):
    info = ctx.attrs.bin[MojoExeInfo]
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), " +
              "which the mojo_package macro does.").format(ctx.label, want, have))
    # The tree kcov's working directory is: the test source and the library's sources at the relative names the line tables use.
    share = ctx.actions.copied_dir("share", {dest: src for dest, src in ctx.attrs.share.items()})
    report = ctx.actions.declare_output(ctx.label.name + ".cobertura.xml")
    cmd = cmd_args(
        ctx.attrs.runner[RunInfo],
        "--kcov",
        _file(ctx.attrs.kcov),
        "--normalize",
        ctx.attrs.normalize[RunInfo],
        "--compiler",
        ctx.attrs.toolchain[MojoToolchainInfo].compiler,
        "--binary",
        info.exe,
        "--share",
        share,
        "--out",
        report.as_output(),
        "--must-contain",
        ctx.attrs.must_contain,
        # A binary that names the library's sources by the directory they were staged in cannot be measured (kcov drops them silently).
        "--refuse-in-binary",
        ".stage/src/",
        hidden = [info.dir],
    )
    for m in ctx.attrs.maps:
        cmd.add("--map", m)
    for i in ctx.attrs.includes:
        cmd.add("--include", i)
    ctx.actions.run(cmd, category = "mojo_cov_run", identifier = ctx.label.name, env = {"BUILDRULES_UNIT_NONCE": _NONCE})
    return _validated(ctx, [DefaultInfo(default_output = report)])

# One test's coverage binary run under kcov: the report in repository paths (docs/contract.md, section 12).
mojo_cov_run_rule = rule(
    impl = _cov_run_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "bin": attrs.dep(providers = [MojoExeInfo]),
        "includes": attrs.list(attrs.string()),
        "kcov": attrs.exec_dep(default = "buildrules//rules/coverage:kcov"),
        "maps": attrs.list(attrs.string()),
        "must_contain": attrs.string(),
        "normalize": attrs.exec_dep(default = "buildrules//rules/coverage:cov_normalize", providers = [RunInfo]),
        "required_isa": attrs.string(default = ""),
        "runner": attrs.exec_dep(default = "buildrules//rules/coverage:cov_run", providers = [RunInfo]),
        "share": attrs.dict(attrs.string(), attrs.source()),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    },
)

def _cov_summary_impl(ctx):
    if not ctx.attrs.reports:
        fail("{}: this package has no test, so there is no coverage to measure: add a test file (tests/test_*.mojo) or do not build :coverage".format(ctx.label))
    out = ctx.actions.declare_output("coverage.txt")
    cmd = cmd_args(ctx.attrs.tool[RunInfo], "--out", out.as_output())
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    # The source behind each expected path, so a source the report omits for having no executable line (a re-export `__init__.mojo`) can be told
    # from one the report missed (cov_summary.zig, hasNoStatements).
    for path, src in ctx.attrs.srcs.items():
        cmd.add("--src", cmd_args(path, src, delimiter = "="))
    for r in ctx.attrs.reports:
        cmd.add(_file(r))
    ctx.actions.run(cmd, category = "mojo_cov_summary", identifier = ctx.label.name)
    return _validated(ctx, [DefaultInfo(default_output = out)])

# The package's line coverage from its tests' reports; fails when one of its own sources is in none.
mojo_cov_summary_rule = rule(
    impl = _cov_summary_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "expect": attrs.list(attrs.string(), default = []),
        "reports": attrs.list(attrs.dep()),
        "srcs": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage:cov_summary", providers = [RunInfo]),
    },
)

def _group_impl(ctx):
    outs = []
    for d in ctx.attrs.deps:
        outs.extend(d[DefaultInfo].default_outputs)
    return _validated(ctx, [DefaultInfo(default_outputs = outs)])

# `:test`, `:build`, `:ci`: building the group builds every dependency (and carries the package's `:check`).
mojo_group = rule(
    impl = _group_impl,
    attrs = {"check": _CHECK_ATTR, "deps": attrs.list(attrs.dep(), default = [])},
)
