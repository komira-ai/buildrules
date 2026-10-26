"""The Mojo actions of a package run on the execution platform of the target platform's kind, and the tools they run are the host's (rules/mojo/exec.bzl).

No farm with Arm or macOS workers is assumed, so the gate is analysis: `examples/mojo/subdirs` is configured for each target platform and what each action
was given is read off the configured targets (`buck.execution_platform` of a node is the execution platform Buck2 chose for it):

  configured  `[buildrules_re] linux_aarch64_properties` and `macos_aarch64_properties` are set (ci/exec_select.buckconfig holds placeholder values, nothing
              runs): every compile, test run, gated library and `.conda` of the package is placed on the platform of its target platform's host; the tools those
              actions run are the host's (the mopm tarball pinned for it, the zig target of mojo_compile, mojo_launch and conda_unpack, the build of `check` for the
              host); the toolchain closure is unpacked on that host. Linux x86_64, at any ISA level, is placed on linux x86_64 with the x86_64 tools. A package whose
              mopm has no tarball pinned for the host is refused, naming the version and the host.
  absent      neither key is set (the farm and the public CI have no such workers): linux x86_64 is as it is with the keys set, and a package built for an Arm
              platform is refused by `:check` (so by every target of the package) with a message that names the missing key.

The linux arm64 switch (`[buildrules_re] linux_arm64_enabled`, rules/platforms.bzl) is off by default, so a state says which way it is, and the four states are:

  absent          switch off (the default), no keys: linux aarch64 is skipped (below); macOS arm64 is refused naming its key. What the public CI runs.
  absent_enabled  switch on, no keys: both Arm platforms are refused naming their key.
  configured      switch on, both keys set (ci/exec_select.buckconfig): as the first paragraph.
  disabled        switch off, both keys set (ci/exec_select_disabled.buckconfig): linux aarch64 is skipped and its platform is NOT registered although its key is set;
                  macOS arm64 is placed and equipped as in `configured`.

Skipped (linux aarch64 with the switch off): every Mojo target of the package is incompatible with the platform (`configured_targets` of an incompatible target
is `None`; `buck2 build --skip-incompatible-targets` lists it as skipped, naming `//platforms:skipped_waiting_on_linux_arm64_hardware`). The check requires that
for every kind of target the package declares, that the constraint is the reason (the `target_compatible_with` of the target, unconfigured), and that the
execution platforms registered are exactly those the state implies (analysis of `//platforms/exec:exec`). It reports "skipped: waiting on linux-arm64 hardware"
and never counts the platform as held.

`exec_problems(ctx, state)` is a list of strings, empty when all is as it must be. ci/exec_select.bxl runs it for the state it is given, and the
public CI runs both (ci/README or .github/workflows/ci.yml).
"""

load("//rules:platforms.bzl", "LINUX_ARM64_SKIPPED")

PACKAGE = "//examples/mojo/subdirs"

# A package whose lock holds the graph of linux-64 alone: built as before for linux x86_64, refused on an Arm platform.
LINUX_64_ONLY_PACKAGE = "//examples/mojo/uncompiled"

# The mopm (0.0.48) that is pinned for linux x86_64 only. Analysed on the target platform it resolves for the host that platform is (`by_host`), as it does when a compile
# on that host runs it. (A package that names it, examples/mojo/uncompiled, has a table with the graph of linux-64 alone, which an Arm platform refuses first.)
OLD_MOPM = "toolchains//:mopm_0_0_48"

X86_PLATFORMS = ["buildrules//platforms:linux_x86_64", "buildrules//platforms:linux_x86_64_v3"]
X86_EXEC = "buildrules//platforms:linux_x86_64"

# A test at an ISA level runs on the execution platform of the level (rules/isa.bzl).
X86_TEST_EXEC = {"buildrules//platforms:linux_x86_64_v3": "buildrules//platforms:exec_x86_64_v3"}

# (target platform, the key of its farm's workers, its execution platform, the zig target of the tools it runs, the pinned mopm tarball's name, the build of check it runs).
# A target platform that states its OS and CPU in the prelude's constraint values, or in both vocabularies (ci/platforms), is the same host as the one of this package's
# own values and is held to the same: the same placement, tools, skip and refusals.
_HOST_ROWS = [
    ("linux_aarch64", "linux_aarch64_properties", "buildrules//platforms:linux_aarch64", "aarch64-linux-musl", "linux-aarch64", "check_linux_aarch64"),
    ("macos_aarch64", "macos_aarch64_properties", "buildrules//platforms:macos_aarch64", "aarch64-macos", "macos-aarch64", "check_macos_arm64"),
]
HOSTS = [
    (target, row[1], row[2], row[3], row[4], row[5])
    for row in _HOST_ROWS
    for target in ["buildrules//platforms:" + row[0], "//ci/platforms:prelude_" + row[0], "//ci/platforms:both_" + row[0]]
]

# The rules whose actions run the compiler or what it built.
_ON_HOST = ["mojo_unit_rule", "mojo_test_run_rule", "mojo_gated_lib_rule", "_mojo_conda"]

# The rules that read files and compare hashes of the committed table: linux x86_64 on every platform.
_ON_X86 = ["mojo_check_rule", "mojo_table_rule", "mojo_workspace_rule"]

def _exec(node):
    return str(getattr(node.attrs_eager(), "buck.execution_platform")).strip("\"")

def _kind(node):
    return node.rule_type.split(":")[-1].split("@")[0]

def _deps(node, pred):
    return [d for d in node.deps() if pred(d.label.name)]

def _package_nodes(ctx, package, platform):
    return [ctx.configured_targets(t.label, target_platform = platform) for t in ctx.uquery().eval(package + ":")]

def _tools_problems(ctx, who, node, want_zig, want_mopm, want_exec):
    """The tools a compile of `node` runs: the zig target of the launcher and the wrapper, the tarball of mopm, and the closure of its toolchain."""
    problems = []
    for name in ["mojo_launch", "mojo_compile"]:
        found = _deps(node, lambda n: n == name)
        if len(found) != 1:
            problems.append("{}: expected one dependency {}, found {}".format(who, name, len(found)))
            continue
        got = found[0].resolved_attrs_eager(ctx).target
        if got != want_zig:
            problems.append("{}: {} is built for {}, not {}".format(who, name, got, want_zig))
    mopm = _deps(node, lambda n: n.startswith("mopm_"))
    if len(mopm) != 1:
        problems.append("{}: expected one mopm, found {}".format(who, len(mopm)))
    else:
        archive = str(mopm[0].resolved_attrs_eager(ctx).archive)
        if want_mopm not in archive:
            problems.append("{}: mopm unpacks {}, not the tarball pinned for {}".format(who, archive, want_mopm))
    toolchain = _deps(node, lambda n: n.startswith("mojo_1_0_0") and not n.endswith("_cov_link"))
    if len(toolchain) != 1:
        problems.append("{}: expected one toolchain, found {}".format(who, len(toolchain)))
        return problems
    closure = _deps(toolchain[0], lambda n: n.endswith("_compiler"))
    if len(closure) != 1:
        problems.append("{}: expected one compiler closure, found {}".format(who, len(closure)))
        return problems
    if _exec(closure[0]) != want_exec:
        problems.append("{}: the compiler closure {} is unpacked on {}, not on {}".format(who, closure[0].label.name, _exec(closure[0]), want_exec))
    unpack = _deps(closure[0], lambda n: n == "conda_unpack")
    if len(unpack) != 1:
        problems.append("{}: expected one conda_unpack, found {}".format(who, len(unpack)))
    elif unpack[0].resolved_attrs_eager(ctx).target != want_zig:
        problems.append("{}: conda_unpack is built for {}, not {}".format(who, unpack[0].resolved_attrs_eager(ctx).target, want_zig))
    return problems

def _host_problems(ctx, platform, exec, test_exec, want_zig, want_mopm, want_check):
    """Every Mojo action of the package, on `platform`: placed on `exec` (a test run on `test_exec`: the platform of its ISA level, if it has one), with the tools of the host."""
    problems = []
    seen = {}
    for node in _package_nodes(ctx, PACKAGE, platform):
        kind = _kind(node)
        who = "{} on {}".format(node.label.name, platform)
        # The coverage builds are compiled with the linux x86_64 toolchain and its coverage link, on linux x86_64 whatever the target platform.
        coverage = node.label.name.endswith("__cov_bin") or node.label.name.endswith("__bc")
        if kind in _ON_HOST and not coverage:
            seen[kind] = True
            want = test_exec if kind == "mojo_test_run_rule" else exec
            if _exec(node) != want:
                problems.append("{}: a {} action is placed on {}, not on {}".format(who, kind, _exec(node), want))
            if kind == "mojo_unit_rule":
                problems += _tools_problems(ctx, who, node, want_zig, want_mopm, exec)
            elif kind == "mojo_test_run_rule":
                starter = _deps(node, lambda n: n == "check_for_host")
                got = [d.label.name for s in starter for d in s.deps()]
                if got != [want_check]:
                    problems.append("{}: the test is started by {}, not by {}".format(who, got, want_check))
        elif (kind in _ON_X86 or coverage) and _exec(node) != X86_EXEC:
            problems.append("{}: a {} action is placed on {}, not on {}".format(who, kind, _exec(node), X86_EXEC))
    for kind in _ON_HOST:
        if kind not in seen:
            problems.append("{}: the package has no {} target, so the platform's placement of it is not held".format(platform, kind))
    return problems

def _refused(ctx, label, platform):
    """The failure of analysing `label` on `platform`, or None. A target incompatible with the platform is not analysed: see `_skipped`."""
    node = ctx.configured_targets(label, target_platform = platform)
    if node == None:
        return "{} is incompatible with {}".format(label, platform)
    r = ctx.lazy.analysis(node).catch().resolve()
    return None if r.is_ok() else str(r.unwrap_err())

def _names_key(why, key):
    return "`[buildrules_re] {}`".format(key) in why

def host_refusal_ok(ctx, label, platform):
    """For a check of ci/subdirs.bzl that a package analyses on `platform`: None when it does, or when it is refused for lack of workers of the platform's kind and
    says which key (the state `absent_enabled` below); else the failure. An incompatible target (the linux arm64 switch is off) is accepted: it is the caller's to report."""
    if ctx.configured_targets(label, target_platform = platform) == None:
        return None
    why = _refused(ctx, label, platform)
    if why == None:
        return None
    for p, key, _, _, _, _ in HOSTS:
        if p == platform and _names_key(why, key):
            return None
    return why

# Every kind of target `mojo_package` declares that a package of examples/mojo/subdirs has, and the sync pair: all are incompatible while the switch is off.
_SKIPPED_TARGETS = ["build", "check", "ci", "conda", "coverage", "lib", "lib_ungated", "sync", "sync_check", "table", "test", "test_tripled", "test_tripled__bin", "test_tripled__cov", "workspace"]

SKIP_CONSTRAINT = "buildrules//platforms:skipped_waiting_on_linux_arm64_hardware"

def _skipped_problems(ctx, platform):
    """Every Mojo target of the package is incompatible with `platform`, for the constraint of the linux arm64 switch, and none is analysed or built."""
    problems = []
    for name in _SKIPPED_TARGETS:
        label = PACKAGE + ":" + name
        if ctx.configured_targets(label, target_platform = platform) != None:
            problems.append("{} is compatible with {} although the linux arm64 switch is off: it would be built, not skipped".format(label, platform))
        want = [t for t in ctx.uquery().eval(label)]
        if len(want) != 1:
            problems.append("{}: expected one target".format(label))
        elif SKIP_CONSTRAINT not in str(want[0].get_attr("target_compatible_with")):
            problems.append("{} does not require {}, so it is not incompatible for the reason the switch gives".format(label, SKIP_CONSTRAINT))
    return problems

def _registered(ctx):
    """The execution platforms this configuration registers (`//platforms/exec:exec`), as labels."""
    node = ctx.configured_targets("//platforms/exec:exec", target_platform = X86_EXEC)
    reg = ctx.analysis(node).providers()[ExecutionPlatformRegistrationInfo]
    return [str(p.label) for p in reg.platforms]

def exec_problems(ctx, state):
    problems = []
    if state not in ("configured", "absent", "absent_enabled", "disabled"):
        return ["ci/exec_select: the state is {}, not `configured`, `absent`, `absent_enabled` or `disabled`".format(repr(state))]
    arm64_on = state in ("configured", "absent_enabled")
    keys = state in ("configured", "disabled")
    # What each Arm platform is in this state: placed (its workers are registered), refused (no key), or skipped (the linux arm64 switch is off).
    registered = _registered(ctx)
    for platform, key, exec, zig, mopm, check in HOSTS:
        is_linux = platform.endswith("linux_aarch64")
        if is_linux and not arm64_on:
            how = "skipped"
        elif keys:
            how = "placed"
        else:
            how = "refused"
        if (how == "placed") != (exec in registered):
            problems.append("the execution platform {} is {} in state `{}`: it is registered exactly when its key is set and (for linux aarch64) the switch is on".format(exec, "registered" if exec in registered else "not registered", state))
        if how == "skipped":
            problems += _skipped_problems(ctx, platform)
            ctx.output.print("{}: {}".format(platform, LINUX_ARM64_SKIPPED))
    # Linux x86_64: the same placement and tools in every state.
    for platform in X86_PLATFORMS:
        problems += _host_problems(ctx, platform, X86_EXEC, X86_TEST_EXEC.get(platform, X86_EXEC), "x86_64-linux-musl", "mopm-0.0.73.tar.gz", "check")
        for label in [PACKAGE + ":lib_ungated", PACKAGE + ":test_tripled", PACKAGE + ":conda"]:
            why = _refused(ctx, label, platform)
            if why:
                problems.append("{} does not analyse on {}: {}".format(label, platform, why))
    for platform in X86_PLATFORMS:
        why = _refused(ctx, LINUX_64_ONLY_PACKAGE + ":lib_ungated", platform)
        if why:
            problems.append("{} (the lock holds linux-64 only) does not analyse on {}: {}".format(LINUX_64_ONLY_PACKAGE, platform, why))
    for platform, key, exec, zig, mopm, check in HOSTS:
        if platform.endswith("linux_aarch64") and not arm64_on:
            continue
        if keys:
            # The table of the package holds the graph of linux-64 alone: an Arm platform refuses it, saying what to do (the toolchain of linux-64 is x86_64). With no worker
            # key the refusal for the missing key comes first, which the other branch holds.
            # (Its `:check`, which every target of the package waits for: the mopm the package names has no tarball for an Arm host either, and that refusal is held below.)
            only = _refused(ctx, LINUX_64_ONLY_PACKAGE + ":check", platform)
            if only == None:
                problems.append("{} (the lock holds linux-64 only) analysed on the Arm platform {}".format(LINUX_64_ONLY_PACKAGE, platform))
            elif "holds a unit graph for linux-64 only" not in only or "`buildrules mojo sync` with a mopm that records" not in only:
                problems.append("{} on {} is refused, but not for holding the graph of linux-64 only, with the fix: {}".format(LINUX_64_ONLY_PACKAGE, platform, only))
            problems += _host_problems(ctx, platform, exec, exec, zig, mopm, check)
            for label in [PACKAGE + ":lib_ungated", PACKAGE + ":lib", PACKAGE + ":test_tripled", PACKAGE + ":conda"]:
                why = _refused(ctx, label, platform)
                if why:
                    problems.append("{} does not analyse on {} with `{}` set: {}".format(label, platform, key, why))
            # A mopm with no tarball pinned for the host is refused, and the refusal names the version and the host.
            old = _refused(ctx, OLD_MOPM, platform)
            host = mopm
            if old == None:
                problems.append("{} analysed on {}, but the mopm (0.0.48) has no tarball pinned for {}".format(OLD_MOPM, platform, host))
            elif "mopm 0.0.48 has no tarball pinned for {}".format(host) not in old:
                problems.append("{} on {} is refused, but not for the mopm that has no pin for {}: {}".format(OLD_MOPM, platform, host, old))
        else:
            for label in [PACKAGE + ":check", PACKAGE + ":lib_ungated", PACKAGE + ":lib", PACKAGE + ":test_tripled", PACKAGE + ":conda"]:
                why = _refused(ctx, label, platform)
                if why == None:
                    problems.append("{} analysed on {} with `{}` not set: a package is built for a platform with no worker kind registered".format(label, platform, key))
                elif not _names_key(why, key):
                    problems.append("{} on {} is refused, but the message does not name `{}`: {}".format(label, platform, key, why))
    return problems
