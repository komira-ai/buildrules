"""The tools of the Mojo rules run on the tool execution platform, and a compile names the macOS hosts it may run on (rules/core/platform.bzl, rules/platforms.bzl).

On a farm the tool tier (the Zig tools, the pinned zig and busybox, the unpackers, `:check`) runs on linux x86_64 and cross-compiles for the host that will run it, as it
always did. On a Mac that runs Buck2 itself (`[buildrules_re] mode = local`) there is no other execution platform, so the tier runs on the Mac: the zig is the macOS
archive unpacked by `unpack`, the busybox is `busybox_macos`, and the one macOS host of a compile is the sentinel `local`. No Mac is needed to hold that: `[buildrules_re]
local_host` names the machine of local mode, so the placement is analysed on any machine (ci/tool_exec/*.buckconfig). `tool_exec_problems(ctx, state)` is a list of strings,
empty when all is as the state holds it; ci/tool_exec.bxl runs it. The states:

  local_linux       `mode = local` on the machine running this (linux x86_64): the tool tier is linux x86_64, and the pins are the linux ones.
  farm              property sets set (ci/exec_select.buckconfig): the same tool tier, and a macOS compile names the identities configured, never the sentinel.
  local_mac         local mode on a Mac, no identity named: every target of a macOS package is placed on the Mac, the pins are the Mac's, the host is `local`.
  local_mac_named   as local_mac with identities named: those identities, unchanged, and not the sentinel.
  local_mac_mixed   the sentinel named beside an identity: a macOS compile is refused.
  sentinel_on_farm  the sentinel named where it is not allowed (a farm): a macOS compile is refused.
"""

load("//rules:platforms.bzl", "DARWIN_LOCAL_HOST", "darwin_hosts_for", "darwin_local_hosts_refusal")
load("//rules/core:platform.bzl", "LINUX_X86_64", "MACOS_AARCH64", "machine_of", "tool_exec_for", "tool_target_for")

STATES = ["local_linux", "farm", "local_mac", "local_mac_named", "local_mac_mixed", "sentinel_on_farm"]

PACKAGE = "//examples/mojo/subdirs"
MAC = "buildrules//platforms:macos_aarch64"
LINUX = "buildrules//platforms:linux_x86_64"
IDENTITY = "27.0-0123456789abcdef"

def _exec(node):
    return str(getattr(node.attrs_eager(), "buck.execution_platform")).strip("\"")

def _pure_problems():
    """The decisions that need no configuration: which machine, which tool platform and target, which hosts."""
    problems = []
    def eq(what, got, want):
        if got != want:
            problems.append("{}: {}, not {}".format(what, repr(got), repr(want)))

    eq("a Mac in local mode runs its tools on the Mac", tool_exec_for("local", "macos-aarch64"), MACOS_AARCH64)
    eq("a Mac on a farm runs them on linux x86_64", tool_exec_for("remote", "macos-aarch64"), LINUX_X86_64)
    eq("linux in local mode", tool_exec_for("local", "linux-x86_64"), LINUX_X86_64)
    eq("linux arm64 in local mode keeps linux x86_64 (it has no tools of its own yet)", tool_exec_for("local", "linux-aarch64"), LINUX_X86_64)
    eq("the zig target of a local Mac", tool_target_for("local", "macos-aarch64"), "aarch64-macos")
    eq("the zig target everywhere else", tool_target_for("remote", "macos-aarch64"), "x86_64-linux-musl")
    eq("the zig target of local linux", tool_target_for("local", "linux-x86_64"), "x86_64-linux-musl")

    eq("no override: the real machine", machine_of("linux-x86_64", "", "remote"), ("linux-x86_64", None))
    eq("an override in local mode", machine_of("linux-x86_64", "macos-aarch64", "local"), ("macos-aarch64", None))
    if machine_of("linux-x86_64", "macos-aarch64", "remote")[1] == None:
        problems.append("local_host is accepted on a farm (mode remote): it must be refused")
    if machine_of("linux-x86_64", "plan9-mips", "local")[1] == None:
        problems.append("a local_host that names no machine is accepted")

    eq("named hosts are kept in local mode on a Mac", darwin_hosts_for([IDENTITY], "local", "macos-aarch64"), ([IDENTITY], False))
    eq("named hosts are kept on a farm", darwin_hosts_for([IDENTITY], "remote", "macos-aarch64"), ([IDENTITY], False))
    eq("no host, local, Mac: the sentinel", darwin_hosts_for([], "local", "macos-aarch64"), ([DARWIN_LOCAL_HOST], True))
    eq("no host, remote: none (the unit refuses)", darwin_hosts_for([], "remote", "macos-aarch64"), ([], False))
    eq("no host, local, linux: none", darwin_hosts_for([], "local", "linux-x86_64"), ([], False))

    eq("the sentinel alone, local execution: allowed", darwin_local_hosts_refusal([DARWIN_LOCAL_HOST], True), None)
    eq("identities alone: allowed", darwin_local_hosts_refusal([IDENTITY], False), None)
    for hosts, local in [([DARWIN_LOCAL_HOST, IDENTITY], True), ([IDENTITY, DARWIN_LOCAL_HOST], False), ([DARWIN_LOCAL_HOST], False), ([IDENTITY], True), ([], True)]:
        if darwin_local_hosts_refusal(hosts, local) == None:
            problems.append("the hosts {} with local_execution {} are accepted: they must be refused".format(hosts, local))
    return problems

def _unit(ctx, platform):
    """The configured compile of the package's library on `platform`, or None."""
    return ctx.configured_targets(PACKAGE + ":lib_ungated", target_platform = platform)

def _tier_problems(ctx, platform, exec, local_mac):
    """The pinned zig and busybox, and `:check`, on `platform`: placed on `exec`; a Mac's zig is unpacked by `unpack`, a farm's by the busybox."""
    problems = []
    for name in ["zig", "zig_next"]:
        node = ctx.configured_targets("//rules/pins:" + name, target_platform = platform)
        who = "//rules/pins:{} on {}".format(name, platform)
        if _exec(node) != exec:
            problems.append("{} is placed on {}, not on {}".format(who, _exec(node), exec))
        attrs = node.resolved_attrs_eager(ctx)
        if local_mac and (attrs.unpack == None or attrs.busybox != None):
            problems.append("{} is not unpacked by `unpack` alone: unpack {}, busybox {}".format(who, attrs.unpack, attrs.busybox))
        if not local_mac and (attrs.unpack != None or attrs.busybox == None):
            problems.append("{} is not unpacked by the busybox alone: unpack {}, busybox {}".format(who, attrs.unpack, attrs.busybox))
        archive = str(attrs.archive)
        if local_mac != ("macos-aarch64" in archive):
            problems.append("{} unpacks {}, not the archive of {}".format(who, archive, "macOS" if local_mac else "linux x86_64"))
    busybox = ctx.configured_targets("//rules/pins:busybox", target_platform = platform)
    if local_mac != ("busybox_macos" in str(busybox.label) or busybox.rule_type.endswith("alias")):
        problems.append("//rules/pins:busybox on {} is {} ({}): {}".format(platform, busybox.label, busybox.rule_type, "the Mac's busybox is busybox_macos" if local_mac else "a farm's is the pinned download"))
    for name in ["conda_unpack", "mojo_launch", "mojo_compile_macos"]:
        node = ctx.configured_targets("//rules/mojo:" + name, target_platform = platform)
        want = "aarch64-macos" if name == "mojo_compile_macos" or local_mac else "x86_64-linux-musl"
        got = node.resolved_attrs_eager(ctx).target
        if got != want:
            problems.append("//rules/mojo:{} on {} is built for {}, not {}".format(name, platform, got, want))
        if _exec(node) != exec:
            problems.append("//rules/mojo:{} on {} is placed on {}, not on {}".format(name, platform, _exec(node), exec))
    return problems

# The targets of a package that build a library and the checks it waits for; coverage is linux x86_64 only and is not among them.
_BUILT = ["check", "conda", "lib", "lib_ungated", "table", "test_tripled", "test_tripled__bin", "workspace"]

def _mac_package_problems(ctx, exec):
    """Every target of the package that builds the library, configured for the Mac, analyses and is placed on `exec`."""
    problems = []
    for name in _BUILT:
        t = struct(label = PACKAGE + ":" + name)
        node = ctx.configured_targets(t.label, target_platform = MAC)
        if node == None:
            problems.append("{} is incompatible with {}".format(t.label, MAC))
            continue
        r = ctx.lazy.analysis(node).catch().resolve()
        if not r.is_ok():
            problems.append("{} does not analyse on {}: {}".format(t.label, MAC, str(r.unwrap_err())))
        elif _exec(node) != exec:
            problems.append("{} is placed on {}, not on {}".format(t.label, _exec(node), exec))
    return problems

def _refused_problem(ctx, text):
    r = ctx.lazy.analysis(_unit(ctx, MAC)).catch().resolve()
    if r.is_ok():
        return ["{} analyses on {}: it must be refused ({})".format(PACKAGE + ":lib_ungated", MAC, text)]
    if text not in str(r.unwrap_err()):
        return ["{} is refused on {}, but not for the reason it carries (expected \"{}\"): {}".format(PACKAGE + ":lib_ungated", MAC, text, str(r.unwrap_err()))]
    return []

def tool_exec_problems(ctx, state):
    if state not in STATES:
        return ["ci/tool_exec: the state is {}, not one of {}".format(repr(state), STATES)]
    problems = _pure_problems()
    if state == "local_linux":
        return problems + _tier_problems(ctx, LINUX, LINUX, False)
    if state == "farm":
        problems += _tier_problems(ctx, LINUX, LINUX, False)
        attrs = _unit(ctx, MAC).resolved_attrs_eager(ctx)
        if list(attrs.macos_hosts) != [IDENTITY] or attrs.local_execution:
            problems.append("a farm's macOS compile names {} (local_execution {}), not {}".format(list(attrs.macos_hosts), attrs.local_execution, [IDENTITY]))
        return problems
    if state == "local_mac":
        problems += _tier_problems(ctx, MAC, MAC, True)
        problems += _mac_package_problems(ctx, MAC)
        attrs = _unit(ctx, MAC).resolved_attrs_eager(ctx)
        if list(attrs.macos_hosts) != [DARWIN_LOCAL_HOST] or not attrs.local_execution:
            problems.append("a local Mac's compile names {} (local_execution {}), not the sentinel".format(list(attrs.macos_hosts), attrs.local_execution))
        return problems
    if state == "local_mac_named":
        problems += _tier_problems(ctx, MAC, MAC, True)
        attrs = _unit(ctx, MAC).resolved_attrs_eager(ctx)
        if list(attrs.macos_hosts) != [IDENTITY] or attrs.local_execution:
            problems.append("a local Mac that names an identity compiles for {} (local_execution {}), not {}".format(list(attrs.macos_hosts), attrs.local_execution, [IDENTITY]))
        return problems
    if state == "local_mac_mixed":
        return problems + _refused_problem(ctx, "is mixed with other hosts")
    return problems + _refused_problem(ctx, "is not allowed here")
