"""Execution platforms: remote by default, local only when asked. A consumer's platforms/BUCK calls `buildrules_execution_platforms`.

`[buildrules_re] mode` chooses where actions run:

  remote (the default, also when `mode` is unset)
      The worker property set is read from `[buildrules_re] linux_x86_64_properties` of the root cell's
      .buckconfig.local, so no endpoint or property value is ever committed. With no property set the
      platform FAILS to load: a setup without a farm never runs an action on the machine by accident.

  local   (`-c buildrules_re.mode=local`)
      Every action runs on the machine running buck2. For CI runners and for people with no farm. It is an
      explicit opt-in and it is refused when a remote-execution endpoint (`[buck2_re_client] engine_address`
      or `cas_address`) or a worker property set is configured too, so a machine that has a farm cannot slip
      into running locally. It stays hermetic: every action's tools are the pinned toolchains' (busybox, zig,
      rustc, ...) staged by buck2, the same inputs and the same command lines as on a farm; the machine
      supplies buck2 itself and its kernel. The ISA platforms (rules/isa.bzl) are registered too and run on the
      machine's CPU: a test that needs `x86-64-v3` fails on a CPU without it, as it would on a worker without it.

Any other value of `mode` is refused.

Every key of `[buildrules_re]` (`mode`, `linux_arm64_enabled`, the property sets, `darwin_macos_hosts`, `macos_library_dirs`) is read from the ROOT cell's configuration
(`read_root_config`), never from the cell that evaluates the file: when a repository that consumes buildrules is itself a cell of another repository, or a package of a
nested cell loads these rules, they all see the one set of values the root cell's .buckconfig and .buckconfig.local hold. `[buck2_re_client]`, which local mode
checks, is Buck2's own client configuration and is read from the root cell too.

Other hosts (remote mode). The Mojo rules run their actions on the execution platform of the target platform's kind (rules/mojo/exec.bzl), because a Mojo
compile cannot target another platform than the one it runs on. A farm that has workers of such a kind says so with one more key each, read like
`linux_x86_64_properties` (the exact worker property set, passed through unchanged):

      [buildrules_re] linux_aarch64_properties   workers that run linux aarch64 actions   (execution platform `//platforms:linux_aarch64`)
      [buildrules_re] macos_aarch64_properties   workers that run macOS arm64 actions     (execution platform `//platforms:macos_aarch64`)
      [buildrules_re] darwin_macos_hosts         the identities of those macOS workers, space separated (`mojo_compile host-identity`); a macOS Mojo compile needs them
      [buildrules_re] macos_library_dirs         optional: directories (separated by ':' or spaces) a macOS test run searches for a library it opens by its bare name, before dyld's defaults

The linux aarch64 platform is registered only while `[buildrules_re] linux_arm64_enabled = true` (default false: linux arm64 farm hardware is not racked); while it is
off the key is ignored and every Mojo target configured for linux aarch64 is incompatible, "skipped: waiting on linux-arm64 hardware" (`linux_arm64_gate`).

A key that is absent registers no platform of that kind and no value of it is ever committed. A Mojo package built for such a platform then fails analysis
and names the key (`:check`, rules/mojo/exec.bzl).
A repo whose platforms/BUCK does not call buildrules_execution_platforms must register `buildrules//platforms:linux_aarch64` and `macos_aarch64` itself, each with the
property set of its key: the keys alone register nothing there. In local mode the keys are refused like `linux_x86_64_properties`: the platform of the machine is the one registered.

ISA levels (rules/isa.bzl): the FIRST platform is ISA-agnostic (the property set as configured, `ISA=x86-64`), so every
compile lands there and on any worker. One more platform per level x86-64-v2..v4 has the same properties with `ISA=<level>`
and the `exec_isa` constraint of its level in its configuration; only an action whose target lists that constraint in
`exec_compatible_with` (test runs) is placed on it, and the farm then requires a worker that reports at least the level.
"""

load("//rules/core:platform.bzl", "by_os_cpu")

def _mode():
    mode = read_root_config("buildrules_re", "mode", "remote").strip()
    if mode not in ("remote", "local"):
        fail("`[buildrules_re] mode` is `{}`: it is `remote` (the default) or `local`.".format(mode))
    return mode

def _refuse_local_beside_remote(key):
    """Local mode is for a machine with no farm. A configured endpoint or property set says there is one."""
    for section, name in [("buck2_re_client", "engine_address"), ("buck2_re_client", "cas_address"), ("buildrules_re", key)]:
        if read_root_config(section, name, "").strip():
            fail(("`[buildrules_re] mode = local` but `[{}] {}` is set: a remote-execution setup is configured, " +
                  "and a machine that has one does not run actions locally. Remove one of the two.").format(section, name))

# The hosts a farm may add to linux x86_64, and the key of each one's worker property set.
EXTRA_HOST_KEYS = {
    "linux-aarch64": "linux_aarch64_properties",
    "macos-aarch64": "macos_aarch64_properties",
}

# THE SWITCH. linux arm64 tests are off until Linux arm64 farm hardware is racked. Re-enabling is one line, in the root cell's .buckconfig.local (or .buckconfig):
#
#     [buildrules_re]
#       linux_arm64_enabled = true
#
# It is a config key, not a constant, so a repo that uses buildrules flips it in its own file, and ci/exec_select.bxl can hold both states. Absent = off.
# What it covers is exactly linux aarch64: the platform `linux_aarch64` registers (below), and the Mojo targets configured for linux aarch64, which are incompatible
# (`linux_arm64_gate`). macOS arm64 is not covered.
LINUX_ARM64_SKIPPED = "skipped: waiting on linux-arm64 hardware"

# The constraint value no platform has: a target that requires it is incompatible, and Buck2 names it when it lists the skipped targets (platforms/BUCK).
_LINUX_ARM64_WAITING = "buildrules//platforms:skipped_waiting_on_linux_arm64_hardware"

def linux_arm64_enabled():
    """True when `[buildrules_re] linux_arm64_enabled` is `true`. Absent or `false`: off (linux arm64 farm hardware is not racked yet). Anything else is refused."""
    v = read_root_config("buildrules_re", "linux_arm64_enabled", "false").strip().lower()
    if v not in ("true", "false"):
        fail("`[buildrules_re] linux_arm64_enabled` is `{}`: it is `true` or `false` (absent = false).".format(v))
    return v == "true"

def linux_arm64_gate():
    """`target_compatible_with` of every Mojo target: empty when the switch is on (the targets are as they were). Off: on a linux aarch64 target platform the
    target requires a constraint no platform has, so it is incompatible, `--skip-incompatible-targets` lists it as skipped, and it is never built (no empty success)."""
    if linux_arm64_enabled():
        return []
    return by_os_cpu({
        "linux_aarch64": [_LINUX_ARM64_WAITING],
        "DEFAULT": [],
    })

def exec_platform_ready(host):
    """True when an execution platform of `host` (`linux-aarch64`, `macos-aarch64`) is registered by this configuration: its key is set (remote mode) or the
    machine running buck2 is of that kind (local mode). Read when a package is loaded, from the root cell's configuration (.buckconfig, .buckconfig.local), whichever cell the package is in.
    linux-aarch64 is never ready while `linux_arm64_enabled` is off."""
    if host == "linux-aarch64" and not linux_arm64_enabled():
        return False
    if _mode() == "local":
        return host_name() == host
    return bool(read_root_config("buildrules_re", EXTRA_HOST_KEYS[host], "").strip())

def exec_platform_missing(host, who):
    """The refusal of `who` on a target platform of `host` whose execution platform is not registered, or "" when it is."""
    if exec_platform_ready(host):
        return ""
    key = EXTRA_HOST_KEYS[host]
    if host == "linux-aarch64" and not linux_arm64_enabled():
        return "{}: {} (`[buildrules_re] linux_arm64_enabled` is not `true`; no linux aarch64 execution platform is registered).".format(who, LINUX_ARM64_SKIPPED)
    if _mode() == "local":
        return ("{}: this target platform is {}, and `[buildrules_re] mode = local` runs actions on this machine only, which is {}. " +
                "Configure a farm with workers of that kind and set `[buildrules_re] {}` in .buckconfig.local (docs/contract.md, section 14).").format(who, host, host_name(), key)
    return ("{}: this target platform is {}, and a Mojo compile runs on the platform it targets, but `[buildrules_re] {}` is not set, so no execution platform " +
            "of that kind is registered. Set it in .buckconfig.local to the exact worker property set of the {} workers of the farm (docs/contract.md, section 14).").format(who, host, key, host)

def _properties(key):
    raw = (read_root_config("buildrules_re", key, "")).strip()
    if not raw:
        fail(("`[buildrules_re] {}` is not set. Copy .buckconfig.local.example to " +
              ".buckconfig.local and fill in the remote-execution endpoint and worker " +
              "properties. Without a farm, opt in to running on this machine with " +
              "`-c buildrules_re.mode=local` (docs/contract.md, section 14); " +
              "the default registers no local execution platform.").format(key))
    props = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            fail("`[buildrules_re] {}`: expected key=value, got `{}`".format(key, pair))
        k, v = pair.split("=", 1)
        props[k.strip()] = v.strip()
    return props

def _executor(props):
    if props == None:
        return CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = False,
            use_limited_hybrid = False,
        )
    return CommandExecutorConfig(
        local_enabled = False,
        remote_enabled = True,
        remote_execution_properties = props,
        remote_execution_use_case = "buck2-default",
        remote_cache_enabled = True,
        allow_cache_uploads = False,
        use_limited_hybrid = False,
    )

def _impl(ctx):
    # Local mode on a host that is not linux x86_64 registers that host's platform (platforms/BUCK) instead.
    first = ctx.attrs.local_platform or ctx.attrs.linux_x86_64
    cfg = first[PlatformInfo].configuration
    platforms = [
        ExecutionPlatformInfo(
            # Named after the platform whose configuration it uses: the
            # configuration keys every exec dep and appears in output paths.
            label = first.label.raw_target(),
            configuration = cfg,
            executor_config = _executor(None if ctx.attrs.local else ctx.attrs.properties),
        ),
    ]
    # The platforms of the other hosts a farm has workers for (one property set each; absent = not registered). They come after the linux x86_64 ones: a
    # target with no constraint on its execution platform is placed on the first.
    for host, props in sorted(ctx.attrs.host_properties.items()):
        plat = ctx.attrs.host_exec[host]
        platforms.append(ExecutionPlatformInfo(
            label = plat.label.raw_target(),
            configuration = plat[PlatformInfo].configuration,
            executor_config = _executor(props),
        ))
    for level, plat in ctx.attrs.isa_platforms.items():
        props = dict(ctx.attrs.properties)
        props["ISA"] = level
        platforms.append(ExecutionPlatformInfo(
            label = plat.label.raw_target(),
            configuration = plat[PlatformInfo].configuration,
            executor_config = _executor(None if ctx.attrs.local else props),
        ))
    return [DefaultInfo(), ExecutionPlatformRegistrationInfo(platforms = platforms)]

_exec_platforms = rule(
    impl = _impl,
    attrs = {
        # `<os>-<cpu>` -> the platform of each other host a property set is configured for, and that property set (remote mode only).
        "host_exec": attrs.dict(attrs.string(), attrs.dep(providers = [PlatformInfo]), default = {}),
        "host_properties": attrs.dict(attrs.string(), attrs.dict(attrs.string(), attrs.string()), default = {}),
        "isa_platforms": attrs.dict(attrs.string(), attrs.dep(providers = [PlatformInfo]), default = {}),
        "linux_x86_64": attrs.dep(providers = [PlatformInfo]),
        "local_platform": attrs.option(attrs.dep(providers = [PlatformInfo]), default = None),
        # Empty in local mode.
        "properties": attrs.dict(attrs.string(), attrs.string()),
        "local": attrs.bool(default = False),
    },
)

def host_name():
    """The machine running buck2, as `<os>-<cpu>` (`linux-x86_64`, `linux-aarch64`, `macos-aarch64`): the spelling of tools/buck2 and rules/pins/hosts.bzl."""
    h = host_info()
    os = "linux" if h.os.is_linux else ("macos" if h.os.is_macos else "other")
    cpu = "x86_64" if h.arch.is_x86_64 else ("aarch64" if h.arch.is_aarch64 else "other")
    return os + "-" + cpu

# What a consumer's platforms/BUCK gets when it does not name the platforms of the other hosts (the generated one, `buildrules init`).
_DEFAULT_HOST_PLATFORMS = {
    "linux-aarch64": "buildrules//platforms:linux_aarch64",
    "macos-aarch64": "buildrules//platforms:macos_aarch64",
}

def buildrules_execution_platforms(name, linux_x86_64, isa_platforms = {}, host_platforms = {}, visibility = None):
    """`isa_platforms`: REAPI `ISA` value (`x86-64-v3`) -> the execution platform of that level (platforms/BUCK `exec_<id>`).
    `host_platforms`: `<os>-<cpu>` -> the platform of that kind (linux x86_64 needs none: it is `linux_x86_64`): the one local mode registers on a machine of
    that kind, and the one remote mode registers when `[buildrules_re] <os>_<cpu>_properties` is set. Empty: the platforms of buildrules (`buildrules//platforms`).

    Remote unless `[buildrules_re] mode = local` (the module doc)."""
    if not host_platforms:
        host_platforms = _DEFAULT_HOST_PLATFORMS
    local_platform = None
    host_exec = {}
    host_properties = {}
    if _mode() == "local":
        _refuse_local_beside_remote("linux_x86_64_properties")
        for key in sorted(EXTRA_HOST_KEYS.values()):
            _refuse_local_beside_remote(key)
        host = host_name()
        if host != "linux-x86_64":
            if host not in host_platforms:
                fail("`[buildrules_re] mode = local` on a {} machine: buildrules knows linux-x86_64 and {}.".format(host, ", ".join(sorted(host_platforms.keys())) or "no other host"))
            # The x86-64 ISA platforms cannot run here, so none is registered.
            local_platform = host_platforms[host]
            isa_platforms = {}
    else:
        for host, key in sorted(EXTRA_HOST_KEYS.items()):
            if not exec_platform_ready(host):
                continue
            if host not in host_platforms:
                fail("`[buildrules_re] {}` is set but this platforms/BUCK names no platform for {}: pass host_platforms = {{\"{}\": ...}}.".format(key, host, host))
            host_exec[host] = host_platforms[host]
            host_properties[host] = _properties(key)
    _exec_platforms(
        name = name,
        host_exec = host_exec,
        host_properties = host_properties,
        linux_x86_64 = linux_x86_64,
        local_platform = local_platform,
        isa_platforms = isa_platforms,
        properties = _properties("linux_x86_64_properties") if _mode() == "remote" else {},
        local = _mode() == "local",
        visibility = visibility,
    )
