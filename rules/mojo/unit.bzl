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
load("//rules:platforms.bzl", "darwin_hosts_here", "darwin_local_hosts_refusal")
load("//rules/coverage/branch:llvm_branch.bzl", "CovBranchInfo", "RAW_PROFILE_VERSION")
load("//rules/cxx:providers.bzl", "NativeArchiveInfo", "NativeLibraryInfo")
load("//rules/native:link.bzl", "LINK_ARCHIVE_DIR", "extra_link_archives", "link_archive_name", "link_cfg")
load("//rules/rust:providers.bzl", "ExecIsaInfo")
load(":providers.bzl", "MojoExeInfo", "MojoLibInfo", "MojoNativeArchiveInfo", "MojoSystemLibsInfo", "MojoTestRunInfo", "MojoToolchainInfo")
load("//rules/core:hang_limit.bzl", "HANG_LIMIT_S", "check_hang_limit", "hang_limit_args")
load("//rules/core:test_runtime.bzl", "check_data_destinations", "macos_library_dirs")
load(":system_libs.bzl", "MojoSystemLibInfo", "lib_dir_args")
load(":test_data.bzl", "DATA_ENV", "LAYOUT_DEFAULT", "LAYOUT_INSTALLED", "check_installed_tree", "check_test_env", "check_test_layout")

# `-c buildrules.unit_nonce=N` changes every unit action's key without changing any input the compiler sees: the compile
# really re-executes, so two builds can be compared byte for byte.
_NONCE = read_config("buildrules", "unit_nonce", "")

# The macOS hosts a compile may run on (rules/platforms.bzl): the identities `[buildrules_re] darwin_macos_hosts` names (space separated: what `mojo_compile host-identity`
# prints on each worker), or, on a Mac that runs Buck2 itself (`mode = local`, none named), the sentinel `local`. A macOS compile is given them (toolchain.cfg, so they
# are part of its action key) and its wrapper refuses a worker that is not one of them, except the sentinel, which skips the comparison. Read from the root cell, where
# the execution platforms are configured.
_MACOS_HOSTS, _LOCAL_EXECUTION = darwin_hosts_here()

# The directories a macOS test run adds to dyld's search for a library it opens by its bare name (`[buildrules_re] macos_library_dirs`, separated by ':' or spaces;
# docs/contract.md). Empty when the key is absent. Only a macOS test run is given them (`--macos-library-dirs`, so they are part of that action's key); a Linux
# run's command is the same with or without the key.
_MACOS_LIBRARY_DIRS = macos_library_dirs(read_root_config("buildrules_re", "macos_library_dirs", ""))

def _file(dep):
    return dep[DefaultInfo].default_outputs[0]

# The `mojo_system_lib` targets of the libraries a test loads (rules/mojo/system_libs.bzl), the same attribute on the test run, the kcov run and the branch-coverage run.
_SYSTEM_LIBS_ATTR = attrs.list(attrs.dep(providers = [MojoSystemLibInfo]), default = [])

# The package's `:check` (rules/mojo/check.bzl) as the validation of a step: a build of the step is red if the table is stale.
_CHECK_ATTR = attrs.option(attrs.dep(), default = None)

def _validated(ctx, info):
    if ctx.attrs.check:
        info.append(ValidationInfo(validations = [
            ValidationSpec(name = "mojo_table_in_sync", validation_result = _file(ctx.attrs.check)),
        ]))
    return info

def check_closure_ids(who, want, have, refuse = fail):
    """Each library the dependency targets provide is the one the graph names. `want` and `have` are `{package: unit id}` (the graph's closure of the unit,
    and what the `MojoLibInfo` of the targets say they were built as); a unit id is `<package>@<version>#mojo<Mojo version>/lib`, so a library built
    from another version of its package, or for another Mojo, is not the graph's. `refuse` is `fail` in a build; a test passes a recorder
    (rules/rust/refusal.bzl)."""
    for package in sorted(want.keys()):
        if package not in have:
            refuse("{}: the graph imports {} as {} but no dependency target says which library it provides for {}: every library of the closure must come from a target of these rules".format(who, package, want[package], package))
        elif have[package] != want[package]:
            refuse(("{}: the graph imports {} as {} but the dependency target provides {}: that library was built from another version of the package, " +
                    "or for another Mojo. Run `buildrules mojo sync` where the library is and where it is imported").format(who, package, want[package], have[package]))

def link_extra_archives(natives):
    """The archives a program links after the ones its graph lists (`extra_link_archives`): those the listed `native_library` targets bring with them through their deps. An
    archive is told from another by its identity, never by its file name."""
    infos = [n[NativeLibraryInfo] for n in natives if NativeLibraryInfo in n]
    return extra_link_archives([i.archives for i in infos], {str(i.archive): True for i in infos}, str)

def link_needs_cxx_runtime(natives):
    """Whether the native libraries (dependencies that may provide `NativeArchiveInfo`; a prebuilt one does not) include one with C++ sources."""
    for n in natives:
        info = n.get(NativeArchiveInfo)
        if info != None and info.cxx:
            return True
    return False

def _unit_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    if tc.version != ctx.attrs.mojo:
        fail("{}: the graph is for Mojo {} but the toolchain {} is Mojo {}".format(ctx.label, ctx.attrs.mojo, ctx.attrs.toolchain.label, tc.version))

    # The sources, at the paths the graph names. The graph's paths start at `graph_base`, a directory of the repository (the package's, or the root
    # when mopm was given --workspace-root), so a source is staged at its repository path less that directory.
    srcs = {}
    where = ctx.label.package
    for s in ctx.attrs.srcs:
        rel = (where + "/" if where else "") + s.short_path
        if ctx.attrs.graph_base:
            if not rel.startswith(ctx.attrs.graph_base + "/"):
                fail("{}: source {} is not under {}".format(ctx.label, s, ctx.attrs.graph_base))
            rel = rel[len(ctx.attrs.graph_base) + 1:]
        srcs[rel] = s
    for want in ctx.attrs.src_paths:
        if want not in srcs:
            fail("{}: the graph names the source {} but the target's `srcs` do not include it".format(ctx.label, want))
    src_dir = ctx.actions.copied_dir("src", srcs)

    # The dependencies' `.mojoc`, flat, and a check that the targets give exactly the closure the graph has, each library built as the graph says.
    closure = {}
    ids = {}
    for d in ctx.attrs.deps:
        closure.update(d[MojoLibInfo].closure)
        ids.update(d[MojoLibInfo].ids)
    if sorted(closure.keys()) != sorted(ctx.attrs.closure_ids.keys()):
        fail("{}: the graph's closure of {} is {} but the dependency targets give {}".format(ctx.label, ctx.attrs.unit_id, sorted(ctx.attrs.closure_ids.keys()), sorted(closure.keys())))
    check_closure_ids(str(ctx.label), ctx.attrs.closure_ids, ids)

    # The native libraries by soname.
    natives = {}
    for soname in ctx.attrs.native_sonames:
        if soname not in ctx.attrs.natives:
            fail("{}: the graph needs the native library {} but `natives` does not provide it".format(ctx.label, soname))
        natives[soname] = _file(ctx.attrs.natives[soname])

    # The toolchain directory mopm is given. mojo_compile (mojo_launch.zig) tells the wrapper where the closure and the zig are.
    macos = "-macos" in tc.cc_target
    if macos:
        # The macOS wrapper links with the host's C driver: no zig, and the deployment target is the version after `-macos.` of the triple.
        refusal = darwin_local_hosts_refusal(list(ctx.attrs.macos_hosts), ctx.attrs.local_execution)
        if refusal:
            fail("{}: {}; a farm's hosts are real identities and never mix with it.".format(ctx.label, refusal))
        if not ctx.attrs.macos_hosts:
            fail(("{}: no macOS host identity. Set `[buildrules_re] darwin_macos_hosts` of the root cell to what `mojo_compile host-identity` prints on each macOS " +
                  "worker (separated by spaces), or build on a Mac with `-c buildrules_re.mode=local` and no worker property set.").format(ctx.label))
        cfg = "wrapper=wrapper\ncompiler=compiler\ndeployment_target={}\n".format(tc.cc_target.rsplit("-macos.", 1)[-1])
        for h in ctx.attrs.macos_hosts:
            cfg += "macos_host={}\n".format(h)
    else:
        cfg = "wrapper=wrapper\ncompiler=compiler\nzig=zig\ncc_target={}\n".format(tc.cc_target)
    for a in ctx.attrs.build_args:
        cfg += "build_arg={}\n".format(a)

    # A program (not a library: nothing is linked) ends its link line with the archives its listed `native_library` targets bring through their deps, and, with a C++
    # native library in the link, the C++ runtime: libc++ and libc++abi of the zig on Linux (`zig cc -lc++`), the host's libc++ on macOS. One `-lc++` ends the line, after every
    # archive, however many of the archives are C++.
    linked = [ctx.attrs.natives[s] for s in ctx.attrs.native_sonames if s in ctx.attrs.natives] if ctx.attrs.kind != "lib" else []
    extras = link_extra_archives(linked)
    extra_names = [link_archive_name(i, a.basename) for i, a in enumerate(extras)]
    cfg += link_cfg(extra_names, link_needs_cxx_runtime(linked))
    zig = _file(ctx.attrs.zig_override) if ctx.attrs.zig_override else tc.zig
    tc_dir = ctx.actions.copied_dir("toolchain", dict({LINK_ARCHIVE_DIR + "/" + extra_names[i]: a for i, a in enumerate(extras)}, **{
        "CLOSURE_SHA256": ctx.actions.write("CLOSURE_SHA256", tc.closure_sha256 + "\n"),
        "compiler": tc.compiler,
        "mojo_compile": _file(ctx.attrs.launcher),
        "toolchain.cfg": ctx.actions.write("toolchain.cfg", cfg),
        "wrapper": _file(ctx.attrs.wrapper),
        "zig": zig,
    }))

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
        ids[ctx.attrs.package] = ctx.attrs.unit_id
        return _validated(ctx, [
            DefaultInfo(default_output = mojoc),
            MojoLibInfo(id = ctx.attrs.unit_id, mojoc = mojoc, closure = closure, ids = ids),
            MojoNativeArchiveInfo(sonames = list(ctx.attrs.native_sonames), archives = natives),
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
        # package name -> unit id, for every unit this one imports (directly or not): the graph's closure, which the dependency targets must give.
        "closure_ids": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # The directory (of the repository) the graph's paths start at: the package's own, or "" when mopm was given --workspace-root.
        "graph_base": attrs.string(default = ""),
        "package": attrs.string(),
        # The file name of the product inside the output directory: `<package>.mojoc` or the executable's name.
        "product": attrs.string(),
        # Paths the graph names for this unit's sources (`srcs` are the files at those paths, in this BUCK file's package).
        "src_paths": attrs.list(attrs.string(), default = []),
        "srcs": attrs.list(attrs.source(), default = []),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "unit_id": attrs.string(),
        # The compile wrapper of the host that runs the unit: mojo_compile on Linux, mojo_compile_macos on macOS.
        "wrapper": attrs.exec_dep(default = "buildrules//rules/mojo:mojo_compile_host"),
        # The host identities a macOS compile may run on (see _MACOS_HOSTS).
        "macos_hosts": attrs.list(attrs.string(), default = _MACOS_HOSTS),
        # True when macos_hosts is the local sentinel (a build on this Mac; rules/platforms.bzl, `darwin_hosts_for`).
        "local_execution": attrs.bool(default = _LOCAL_EXECUTION),
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
    ids = {}
    for d in ctx.attrs.deps:
        closure.update(d[MojoLibInfo].closure)
        ids.update(d[MojoLibInfo].ids)
    closure[ctx.attrs.package] = out
    ids[ctx.attrs.package] = ctx.attrs.unit_id
    return [DefaultInfo(default_output = out, sub_targets = sub_targets), MojoLibInfo(id = ctx.attrs.unit_id, mojoc = out, closure = closure, ids = ids)]

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
# LD_LIBRARY_PATH (`--ld-library-path`, made absolute), nothing else is added to the environment. Its native libraries are found through its
# runpath ($ORIGIN/lib). The build action is `check marker` (rules/check): the marker is written, `passed`, only when the binary exited 0; the
# `buck2 test` command is `check run`, the same start without a marker.

def _data_dir(ctx):
    """The directory a test finds its staged data in, or None for a test without data: a copy of each file (a label's default output keeps its executable
    bit) at its staged path, so the directory is an input of the action by the digests of the files in it."""
    where = str(ctx.label.raw_target())
    check_test_env(where, ctx.attrs.test_env)
    check_test_layout(where, ctx.attrs.test_layout)
    if not ctx.attrs.data:
        return None
    check_data_destinations(where + ": data", ctx.attrs.data.keys())
    return ctx.actions.copied_dir("data", dict(ctx.attrs.data))

def _start_options(ctx, data_dir):
    """`check run|marker` options that give a test its scratch, data and variables. Always `--private-scratch`: a fresh, empty TMPDIR and TEST_TMPDIR and
    HOME of the run's own (docs/contract.md, section 12.9). Then the data: in the default layout the data directory is the working directory and is named by
    `BUILDRULES_TEST_DATA` (made absolute, because the action runs in the execution root); in the installed layout (`--installed`) a fresh root is made in the
    scratch, the binary is copied to `<root>/bin/`, the data directory is copied to `<root>/share` (named by `BUILDRULES_TEST_DATA`) and `<root>` is the
    working directory. Then each `test_env` entry. They are arguments of the action, so a change to any is a new action key."""
    opts = ["--private-scratch"]
    if ctx.attrs.test_layout == LAYOUT_INSTALLED:
        opts += ["--installed"]
        if data_dir:
            opts += ["--install-share", data_dir, "--share-env", DATA_ENV]
    elif data_dir:
        opts += ["--env", cmd_args(DATA_ENV + "=", data_dir, delimiter = ""), "--abs", DATA_ENV, "--cwd-env", DATA_ENV]
    for name in sorted(ctx.attrs.test_env.keys()):
        opts += ["--env", "{}={}".format(name, ctx.attrs.test_env[name])]
    return opts

def _test_run_impl(ctx):
    info = ctx.attrs.bin[MojoExeInfo]
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}. A test at an ISA level must run on a platform " +
              "that has it: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), which the mojo_package " +
              "macro does, so the farm schedules the run on a worker of at least that level.").format(ctx.label, want, have))
    check = ctx.attrs._check_exe[RunInfo]
    compiler = ctx.attrs.toolchain[MojoToolchainInfo].compiler
    libs = cmd_args(compiler, "/lib", delimiter = "")
    data_dir = _data_dir(ctx)
    start = _start_options(ctx, data_dir)

    # The system libraries the unit graph pins for this test (system_libs.bzl): on its library path, after the compiler's lib on Linux, first in dyld's fallback path on macOS.
    start = start + lib_dir_args(ctx.attrs.system_libs)
    if _MACOS_LIBRARY_DIRS and "-macos" in ctx.attrs.toolchain[MojoToolchainInfo].cc_target:
        start = ["--macos-library-dirs", _MACOS_LIBRARY_DIRS] + start
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")

    # The hang limit (rules/core/hang_limit.bzl): every welded test run carries it, so a test that hangs is stopped and red, whatever the executor's own timeout.
    # Only the welded run: the command of `buck2 test` below is the runner's to time out.
    where = str(ctx.label.raw_target())
    check_hang_limit(where, ctx.attrs.test_hang_limit_s)
    hang = hang_limit_args(where, ctx.attrs.test_hang_limit_s)
    ctx.actions.run(
        cmd_args(check, "marker", "--out", marker.as_output(), "--ld-library-path", libs, start, hang, "--", info.exe, hidden = [info.dir]),
        category = ctx.attrs.category,
        identifier = ctx.label.name,
        env = {"BUILDRULES_UNIT_NONCE": _NONCE},
    )

    # The command of `buck2 test`: the same start, without a marker.
    run = cmd_args(check, "run", "--ld-library-path", libs, start, "--", info.exe, hidden = [info.dir])
    return _validated(ctx, [
        DefaultInfo(default_output = marker),
        MojoTestRunInfo(marker = marker),
        ExternalRunnerTestInfo(
            type = "custom",
            command = [run],
            labels = ["test", "mojo"],
        ),
    ])

mojo_test_run_rule = rule(
    impl = _test_run_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "bin": attrs.dep(providers = [MojoExeInfo]),
        "category": attrs.string(default = "mojo_test"),
        # The longest the test run may take before it is stopped as hung (rules/core/hang_limit.bzl): positive whole seconds. Raise it for a test that is
        # genuinely long; never lower it to make a test pass.
        "test_hang_limit_s": attrs.int(default = HANG_LIMIT_S),
        # The files the test reads, `{staged path: file or target}`: copied to a directory that is the test's working directory and is named by
        # BUILDRULES_TEST_DATA (test_data.bzl). A target's default output is staged with the executable bit it has.
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "required_isa": attrs.string(default = ""),
        # The shared libraries the test opens by their bare names, as the unit graph's `loads` names them (rules/mojo/system_libs.bzl): each directory is put on the
        # library path of the run, in this order.
        "system_libs": _SYSTEM_LIBS_ATTR,
        # The variables the test is given besides its own: `{NAME: value}`.
        "test_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # `default` or `installed` (test_data.bzl): where the test runs. The installed layout is a fresh root per test, the binary at `<root>/bin/<exe>`,
        # the data under `<root>/share`, the working directory `<root>`.
        "test_layout": attrs.string(default = LAYOUT_DEFAULT),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check_for_host", providers = [RunInfo]),
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
        cmd_args(ctx.attrs._check_exe[RunInfo], "copy", lib.mojoc, out.as_output(), hidden = markers),
        category = "mojo_gate",
        identifier = ctx.label.name,
    )
    closure = dict(lib.closure)
    closure[ctx.attrs.package] = out
    natives = ctx.attrs.lib.get(MojoNativeArchiveInfo) or MojoNativeArchiveInfo(sonames = [], archives = {})
    return _validated(ctx, [
        DefaultInfo(default_output = out),
        MojoLibInfo(id = lib.id, mojoc = out, closure = closure, ids = lib.ids),
        # The libraries are not behind the tests: they are inputs of the library's own compile and of its tests, which `out` waits for.
        MojoNativeArchiveInfo(sonames = natives.sonames, archives = natives.archives),
        # The pinned system libraries are no input of the library's bytes either: a dependent that runs its tests through other rules is given the directories
        # (rules/mojo/system_libs.bzl), so its tests find the libraries this package's own tests find.
        MojoSystemLibsInfo(dirs = [l[MojoSystemLibInfo].dir for l in ctx.attrs.system_libs]),
    ])

# The library as the world sees it (`:lib`): the compiled library (`:lib_ungated`, which the package's own tests import) behind the
# runs of all of its tests. Same bytes as the compiled `.mojoc`, so a dependent's cache key moves only when the library does.
mojo_gated_lib_rule = rule(
    impl = _gated_lib_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "lib": attrs.dep(providers = [MojoLibInfo]),
        "package": attrs.string(),
        # Every `mojo_system_lib` the package's unit graph pins, handed on as `MojoSystemLibsInfo` (not an input of the gated file).
        "system_libs": _SYSTEM_LIBS_ATTR,
        "test_runs": attrs.list(attrs.dep(providers = [MojoTestRunInfo]), default = []),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check_for_host", providers = [RunInfo]),
    },
)

def _coverage_tree(ctx):
    """The tree a test's coverage run has as its working directory: the test source and the library's sources at the relative names the line tables use,
    and the test's staged data (the same files the test run is given, test_data.bzl): the test reads them from its working directory, and from the
    directory BUILDRULES_TEST_DATA names, which is this tree. Used by the kcov run and by the branch run, so both see the files the test run does."""
    where = str(ctx.label.raw_target())
    check_test_env(where, ctx.attrs.test_env)
    check_test_layout(where, ctx.attrs.test_layout)
    check_data_destinations(where + ": data", ctx.attrs.data.keys())
    installed = ctx.attrs.test_layout == LAYOUT_INSTALLED
    data_dir = None
    tree = {dest: src for dest, src in ctx.attrs.share.items()}
    if installed:
        # The data is its own tree (it becomes `<root>/share`); the root holds the sources beside `bin/` and `share/`.
        check_installed_tree(where, tree.keys())
        if ctx.attrs.data:
            data_dir = ctx.actions.copied_dir("data", dict(ctx.attrs.data))
    else:
        for dest, src in ctx.attrs.data.items():
            for held in tree.keys():
                if dest == held or held.startswith(dest + "/") or dest.startswith(held + "/"):
                    fail("{}: the staged data {} collides with {}, which the coverage tree holds (the test's source or the library's)".format(where, dest, held))
            tree[dest] = src
    return ctx.actions.copied_dir("share", tree), installed, data_dir

def _cov_run_impl(ctx):
    info = ctx.attrs.bin[MojoExeInfo]
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), " +
              "which the mojo_package macro does.").format(ctx.label, want, have))
    share, installed, data_dir = _coverage_tree(ctx)
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
    # A fresh, empty TMPDIR, TEST_TMPDIR and HOME of the run's own, as the test run has (`--private-scratch`); the installed layout copies the binary to
    # `<root>/bin/`, the sources into `<root>` and the data to `<root>/share`, which `--data-env` then names (cov_run.zig).
    cmd.add("--private-scratch")
    if installed:
        cmd.add("--installed")
        if data_dir:
            cmd.add("--data", data_dir)
    if ctx.attrs.data:
        cmd.add("--data-env", DATA_ENV)
    for name in sorted(ctx.attrs.test_env.keys()):
        cmd.add("--env", "{}={}".format(name, ctx.attrs.test_env[name]))
    cmd.add(lib_dir_args(ctx.attrs.system_libs))
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
        # The test's staged data and variables: the very ones of its test run (`mojo_test_run_rule`).
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "test_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "test_layout": attrs.string(default = LAYOUT_DEFAULT),
        "includes": attrs.list(attrs.string()),
        "kcov": attrs.exec_dep(default = "buildrules//rules/coverage:kcov"),
        "maps": attrs.list(attrs.string()),
        "must_contain": attrs.string(),
        "normalize": attrs.exec_dep(default = "buildrules//rules/coverage:cov_normalize", providers = [RunInfo]),
        "required_isa": attrs.string(default = ""),
        "runner": attrs.exec_dep(default = "buildrules//rules/coverage:cov_run", providers = [RunInfo]),
        "share": attrs.dict(attrs.string(), attrs.source()),
        # The system libraries of the test run (rules/mojo/system_libs.bzl), on the library path of the run under kcov as well.
        "system_libs": _SYSTEM_LIBS_ATTR,
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    },
)

# ---- branch coverage (rules/coverage/branch/README.md) -------------------------------------------------------------------------------------
# Per test, five actions after the bitcode (`<stem>__bc`, a `mopm unit build` of the test as `mojo build --emit llvm-bitcode`):
#   mojo_cov_pgo_link        the bitcode instrumented with IR profile counters by Mojo's own lld, linked as a release test is, with the profile runtime
#   mojo_cov_branch_run      that binary run in the tree of the test's sources, the raw profiles merged by llvm-profdata
#   mojo_cov_branch_annotate the bitcode with that profile applied by lld, as IR text whose branches carry their counts
#   mojo_cov_branch_classify the branches of the library's sources in that IR, as lcov BRDA records in repository paths

def cov_link_natives(label, sonames, provided, needs, refuse = fail):
    """Checks the native libraries the instrumented link is given against the unit's: every library the unit links is given, no other is, and
    the order is the graph's, which is the order of the ordinary test link (a library before every library it needs: a static archive resolves
    what the libraries before it left undefined). `sonames` is the unit's list in the graph's order, `provided` the sonames the target has a
    file for, `needs` each soname's list of the sonames it needs. `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    for soname in sonames:
        if soname not in provided:
            refuse("{}: the unit links the native library {} and the instrumented link of its branch coverage is not given it: add it to `natives` (the instrumented test cannot link without it)".format(label, soname))
    for soname in provided:
        if soname not in sonames:
            refuse("{}: `natives` gives the instrumented link {}, which the unit does not link".format(label, soname))
    position = {soname: i for i, soname in enumerate(sonames)}
    for soname in sonames:
        for need in needs.get(soname, []):
            if need not in position:
                refuse("{}: {} needs {}, which the unit's link does not carry".format(label, soname, need))
            elif position[need] < position[soname]:
                refuse("{}: {} is linked before {}, which needs it: a static archive comes before every archive it needs, as in the ordinary link".format(label, need, soname))

def _is_static(soname):
    # A static native library is `lib<stem>.a` (docs/contract.md, section 12.4); every other native is a shared object.
    return soname.endswith(".a")

def _pgo_impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    llvm = ctx.attrs.branch[CovBranchInfo]
    bc = ctx.attrs.bc[MojoExeInfo]
    out = ctx.actions.declare_output(ctx.label.name)

    # The unit's native libraries, as the ordinary test link gets them: one flag each, in the graph's order.
    sonames = ctx.attrs.native_sonames
    cov_link_natives(ctx.label, sonames, ctx.attrs.natives, ctx.attrs.native_needs)
    cmd = cmd_args(
        ctx.attrs.tool[RunInfo],
        "link",
        "--compiler",
        tc.compiler,
        "--zig",
        tc.zig,
        "--target",
        tc.cc_target,
        "--lld",
        llvm.lld,
        "--runtime",
        llvm.runtime,
        "--bitcode",
        bc.exe,
        "--out",
        out.as_output(),
        "--nm",
        llvm.nm,
        hidden = [llvm.lld_dir, llvm.tools_dir, bc.dir],
    )
    for soname in sonames:
        cmd.add("--native", _file(ctx.attrs.natives[soname]))

    # The archives the listed libraries bring through their deps, then the C++ runtime, end the line as they end the ordinary test link's (`link_extra_archives`,
    # `link_needs_cxx_runtime`).
    linked = [ctx.attrs.natives[s] for s in sonames]
    for a in link_extra_archives(linked):
        cmd.add("--link-tail", a)
    if link_needs_cxx_runtime(linked):
        cmd.add("--link-tail", "-lc++")
    ctx.actions.run(
        cmd,
        category = "mojo_cov_pgo_link",
        identifier = ctx.label.name,
        env = {"BUILDRULES_UNIT_NONCE": _NONCE},
    )

    # The shared libraries the binary loads: an ordinary test finds them in `lib/` beside it (its run path); `[libs]` is that directory for the
    # run of the instrumented binary (`cov_branch run --lib-dir`). A static archive is in the binary and is not loaded.
    shared = {soname: _file(ctx.attrs.natives[soname]) for soname in sonames if not _is_static(soname)}
    sub = {"libs": [DefaultInfo(default_output = ctx.actions.copied_dir("libs", shared))]} if shared else {}
    return _validated(ctx, [DefaultInfo(default_output = out, sub_targets = sub)])

# One test's bitcode instrumented with profile counters and linked with the unit's native libraries (rules/coverage/branch/cov_branch_link.zig).
mojo_cov_pgo_rule = rule(
    impl = _pgo_impl,
    attrs = {
        "branch": attrs.exec_dep(providers = [CovBranchInfo]),
        "bc": attrs.dep(providers = [MojoExeInfo]),
        "check": _CHECK_ATTR,
        # The unit's native libraries in the graph's order, the target of each, and what each needs (`needs` of the graph).
        "native_needs": attrs.dict(attrs.string(), attrs.list(attrs.string()), default = {}),
        "native_sonames": attrs.list(attrs.string(), default = []),
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:cov_branch", providers = [RunInfo]),
    },
)

def _branch_run_impl(ctx):
    have = ctx.attrs._exec_isa[ExecIsaInfo].level
    want = ctx.attrs.required_isa
    if not isa_satisfies(have, want):
        fail(("{}: built for ISA {} but its execution platform reports ISA={}: set exec_compatible_with = test_exec_compatible_with() (rules/isa.bzl), " +
              "which the mojo_package macro does.").format(ctx.label, want, have))
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    llvm = ctx.attrs.branch[CovBranchInfo]

    # The tree the test runs in: the test source and the library's sources at the relative names the line tables use, and its staged data, as the kcov run's.
    # In the installed layout (`test_layout = "installed"`) the instrumented binary is run from `<root>/bin`, the sources are copied into `<root>` and the data into
    # `<root>/share`, with a TMPDIR, TEST_TMPDIR and HOME of the run's own: the layout of the test run and of the kcov run (`cov_branch run --installed`).
    share, installed, data_dir = _coverage_tree(ctx)
    profdata = ctx.actions.declare_output(ctx.label.name + ".profdata")
    cmd = cmd_args(
        ctx.attrs.tool[RunInfo],
        "run",
        "--compiler",
        tc.compiler,
        "--share",
        share,
        "--label",
        str(ctx.label.raw_target()),
        "--profdata",
        llvm.profdata,
        "--raw-version",
        str(RAW_PROFILE_VERSION),
        "--binary",
        ctx.attrs.pgo[DefaultInfo].default_outputs[0],
        "--out",
        profdata.as_output(),
        hidden = [llvm.tools_dir],
    )

    # The shared native libraries the instrumented binary loads (`[libs]` of the link): found through the library path, as an ordinary test finds
    # them through the `lib/` beside it.
    libs = ctx.attrs.pgo[DefaultInfo].sub_targets.get("libs")
    if libs:
        cmd.add("--lib-dir", libs[DefaultInfo].default_outputs[0])

    # The system libraries of the test run (rules/mojo/system_libs.bzl), after those.
    cmd.add(lib_dir_args(ctx.attrs.system_libs))

    if installed:
        cmd.add("--installed")
        if data_dir:
            cmd.add("--data", data_dir)

    # The variables of the test run, and the directory of its staged data (the tree, which is also the working directory; `<root>/share` when installed).
    if ctx.attrs.data:
        cmd.add("--data-env", DATA_ENV)
    for name in sorted(ctx.attrs.test_env.keys()):
        cmd.add("--env", "{}={}".format(name, ctx.attrs.test_env[name]))
    ctx.actions.run(cmd, category = "mojo_cov_branch_run", identifier = ctx.label.name, env = {"BUILDRULES_UNIT_NONCE": _NONCE})
    return _validated(ctx, [DefaultInfo(default_output = profdata)])

# One test's instrumented binary run, its raw profiles merged (rules/coverage/branch/cov_branch_run.zig).
mojo_cov_branch_run_rule = rule(
    impl = _branch_run_impl,
    attrs = {
        "branch": attrs.exec_dep(providers = [CovBranchInfo]),
        "check": _CHECK_ATTR,
        # The test's staged data and variables: the very ones of its test run and its kcov run.
        "data": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "pgo": attrs.dep(),
        "required_isa": attrs.string(default = ""),
        "share": attrs.dict(attrs.string(), attrs.source()),
        # The system libraries of the test run (rules/mojo/system_libs.bzl), on the library path of the instrumented binary's run.
        "system_libs": _SYSTEM_LIBS_ATTR,
        "test_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "test_layout": attrs.string(default = LAYOUT_DEFAULT),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:cov_branch", providers = [RunInfo]),
        "_exec_isa": attrs.exec_dep(default = "buildrules//rules/rust:exec_isa", providers = [ExecIsaInfo]),
    },
)

def _annotate_impl(ctx):
    llvm = ctx.attrs.branch[CovBranchInfo]
    bc = ctx.attrs.bc[MojoExeInfo]
    ir = ctx.actions.declare_output(ctx.label.name + ".ll")
    ctx.actions.run(
        cmd_args(
            ctx.attrs.tool[RunInfo],
            "annotate",
            "--lld",
            llvm.lld,
            "--profdata",
            llvm.profdata,
            "--bitcode",
            bc.exe,
            "--profile",
            ctx.attrs.profdata[DefaultInfo].default_outputs[0],
            "--binary",
            ctx.attrs.pgo[DefaultInfo].default_outputs[0],
            "--out",
            ir.as_output(),
            hidden = [llvm.lld_dir, llvm.tools_dir, bc.dir],
        ),
        category = "mojo_cov_branch_annotate",
        identifier = ctx.label.name,
        env = {"BUILDRULES_UNIT_NONCE": _NONCE},
    )
    return _validated(ctx, [DefaultInfo(default_output = ir)])

# One test's profile applied to its bitcode, the module printed after the pass (rules/coverage/branch/cov_branch_annotate.zig).
mojo_cov_branch_annotate_rule = rule(
    impl = _annotate_impl,
    attrs = {
        "bc": attrs.dep(providers = [MojoExeInfo]),
        "branch": attrs.exec_dep(providers = [CovBranchInfo]),
        "check": _CHECK_ATTR,
        "pgo": attrs.dep(),
        "profdata": attrs.dep(),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:cov_branch", providers = [RunInfo]),
    },
)

def _classify_impl(ctx):
    # The library's sources at the names its `.mojoc` gives them (`<import>/<file>`), which the classifier reads for the token at each branch.
    src = ctx.actions.copied_dir("src", {dest: s for dest, s in ctx.attrs.srcs.items()})
    info = ctx.actions.declare_output(ctx.label.name + ".info")
    cmd = cmd_args(
        ctx.attrs.tool[RunInfo],
        "--ir",
        ctx.attrs.ir[DefaultInfo].default_outputs[0],
        "--out",
        info.as_output(),
        "--map",
        ctx.attrs.map,
        "--src",
        cmd_args(src, format = "{}/"),
        # Where the standard library's sources are named: a String's last-reference test is its code inlined at the branch.
        "--stdlib",
        "oss/modular/",
        # The standard library, the closure's other packages, the test itself and the compile unit with no file are not measured. Any other
        # name fails the action, so a library compiled from a path of its own cannot read as measured with nothing in it.
        "--exclude",
        "oss/modular/",
    )
    for d in ctx.attrs.excludes:
        cmd.add("--exclude", d)
    for f in ctx.attrs.exclude_files:
        cmd.add("--exclude-file", f)
    cmd.add("--exclude-file", "<unknown>")
    ctx.actions.run(cmd, category = "mojo_cov_branch_classify", identifier = ctx.label.name)
    return _validated(ctx, [DefaultInfo(default_output = info)])

# The branches of one test's annotated IR that fall in the library's sources, as lcov BRDA records in repository paths
# (rules/coverage/branch/cov_branch_classify.zig).
mojo_cov_branch_classify_rule = rule(
    impl = _classify_impl,
    attrs = {
        "check": _CHECK_ATTR,
        "exclude_files": attrs.list(attrs.string(), default = []),
        "excludes": attrs.list(attrs.string(), default = []),
        "ir": attrs.dep(),
        "map": attrs.string(),
        "srcs": attrs.dict(attrs.string(), attrs.source()),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage/branch:cov_branch_classify", providers = [RunInfo]),
    },
)

def _cov_summary_impl(ctx):
    if ctx.attrs.unmeasured and not (ctx.attrs.reports and ctx.attrs.expect):
        fail("{}: {} exists but this package has no library or no test, so it makes no coverage and no source can be unmeasured: remove the file, or add the library and tests".format(ctx.label, ctx.attrs.unmeasured.short_path))
    if not ctx.attrs.reports:
        fail("{}: this package has no test, so there is no coverage to measure: add a test file (tests/test_*.mojo) or do not build :coverage".format(ctx.label))
    out = ctx.actions.declare_output("coverage.txt")
    cmd = cmd_args(ctx.attrs.tool[RunInfo], "--out", out.as_output())
    for e in ctx.attrs.expect:
        cmd.add("--expect", e)
    # The source behind each expected path, so a source the report omits for having no executable line (a re-export `__init__.mojo`) can be told
    # from one the report missed (mojo_decl.zig, hasNoStatements). The package's tests are given too, under their repository paths: their hit
    # lines are the calls that tell an inlined function from one nobody calls (mojo_calls.zig); they are not in `expect`, so nothing of them is counted.
    for path, src in ctx.attrs.srcs.items():
        cmd.add("--src", cmd_args(path, src, delimiter = "="))
    for b in ctx.attrs.branches:
        cmd.add("--branch-lcov", _file(b))

    # The package's `coverage_unmeasured.txt`, if it has one: the sources kcov cannot record, an input of the action (rules/coverage/tools/cov_unmeasured.zig).
    if ctx.attrs.unmeasured:
        cmd.add("--unmeasured", cmd_args(ctx.attrs.unmeasured_root, ctx.attrs.unmeasured, delimiter = "="))

    # What no test compiled: the lines of the functions no report records, and (with branch records) the arms of their decision words. The
    # summary counts them as found and not hit, and writes them as one more report and one more branch record file (rules/coverage/tools/mojo_src.zig).
    uncompiled = ctx.actions.declare_output("uncompiled.cobertura.xml")
    cmd.add("--uncompiled-lines", uncompiled.as_output())
    uncompiled_branches = None
    if ctx.attrs.branches:
        uncompiled_branches = ctx.actions.declare_output("uncompiled.branches.info")
        cmd.add("--uncompiled-branches", uncompiled_branches.as_output())

    # What was left out of those lines, and why: the lines of a function a test is seen to reach (an inlined function's, a compile-time arm's) and the
    # functions every use of which is in an arm no report records (rules/coverage/tools/mojo_calls.zig, mojo_gate.zig).
    excluded = ctx.actions.declare_output("uncompiled.excluded.txt")
    cmd.add("--uncompiled-report", excluded.as_output())
    for r in ctx.attrs.reports:
        cmd.add(_file(r))
    ctx.actions.run(cmd, category = "mojo_cov_summary", identifier = ctx.label.name)

    # `:coverage[reports]`: the per-line records the summary was made from, one kcov Cobertura file per test and the lines no test compiled as
    # one more (docs/contract.md, section 12.4). They are the very files the summary action read or wrote, so a consumer that takes them gets what
    # `coverage.txt` counted. `:coverage[branches]` likewise: the branch records, one lcov file per test and the arms of the decision words no
    # test compiled as one more, the very files the `branches` rows were counted from (`covcheck --branch-lcov`).
    # `reports_of_tests` and `reports_uncompiled` (`branches_of_tests`, `branches_uncompiled`) are the two parts, for a consumer that wants them apart.
    tests = [_file(r) for r in ctx.attrs.reports]
    sub = {
        "excluded_uncompiled": [DefaultInfo(default_output = excluded)],
        "reports": [DefaultInfo(default_outputs = tests + [uncompiled])],
        "reports_of_tests": [DefaultInfo(default_outputs = tests)],
        "reports_uncompiled": [DefaultInfo(default_output = uncompiled)],
    }
    if ctx.attrs.branches:
        btests = [_file(b) for b in ctx.attrs.branches]
        sub["branches"] = [DefaultInfo(default_outputs = btests + [uncompiled_branches])]
        sub["branches_of_tests"] = [DefaultInfo(default_outputs = btests)]
        sub["branches_uncompiled"] = [DefaultInfo(default_output = uncompiled_branches)]
    return _validated(ctx, [DefaultInfo(default_output = out, sub_targets = sub)])

# The package's line coverage from its tests' reports, and its branch coverage from their branch records; fails when one of its own sources
# is in no report.
mojo_cov_summary_rule = rule(
    impl = _cov_summary_impl,
    attrs = {
        "branches": attrs.list(attrs.dep(), default = []),
        "check": _CHECK_ATTR,
        "expect": attrs.list(attrs.string(), default = []),
        "reports": attrs.list(attrs.dep()),
        "srcs": attrs.dict(attrs.string(), attrs.source(), default = {}),
        "tool": attrs.exec_dep(default = "buildrules//rules/coverage:cov_summary", providers = [RunInfo]),
        # `coverage_unmeasured.txt` and the package's directory from the repository root, the base of its paths (absent: every source is required in a report).
        "unmeasured": attrs.option(attrs.source(), default = None),
        "unmeasured_root": attrs.string(default = ""),
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
