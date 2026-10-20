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

ISA levels (rules/isa.bzl): the FIRST platform is ISA-agnostic (the property set as configured, `ISA=x86-64`), so every
compile lands there and on any worker. One more platform per level x86-64-v2..v4 has the same properties with `ISA=<level>`
and the `exec_isa` constraint of its level in its configuration; only an action whose target lists that constraint in
`exec_compatible_with` (test runs) is placed on it, and the farm then requires a worker that reports at least the level.
"""

def _mode():
    mode = read_config("buildrules_re", "mode", "remote").strip()
    if mode not in ("remote", "local"):
        fail("`[buildrules_re] mode` is `{}`: it is `remote` (the default) or `local`.".format(mode))
    return mode

def _refuse_local_beside_remote(key):
    """Local mode is for a machine with no farm. A configured endpoint or property set says there is one."""
    for section, name in [("buck2_re_client", "engine_address"), ("buck2_re_client", "cas_address"), ("buildrules_re", key)]:
        if read_config(section, name, "").strip():
            fail(("`[buildrules_re] mode = local` but `[{}] {}` is set: a remote-execution setup is configured, " +
                  "and a machine that has one does not run actions locally. Remove one of the two.").format(section, name))

def _properties(key):
    raw = (read_config("buildrules_re", key, "")).strip()
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
    cfg = ctx.attrs.linux_x86_64[PlatformInfo].configuration
    platforms = [
        ExecutionPlatformInfo(
            # Named after the platform whose configuration it uses: the
            # configuration keys every exec dep and appears in output paths.
            label = ctx.attrs.linux_x86_64.label.raw_target(),
            configuration = cfg,
            executor_config = _executor(None if ctx.attrs.local else ctx.attrs.properties),
        ),
    ]
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
        "isa_platforms": attrs.dict(attrs.string(), attrs.dep(providers = [PlatformInfo]), default = {}),
        "linux_x86_64": attrs.dep(providers = [PlatformInfo]),
        # Empty in local mode.
        "properties": attrs.dict(attrs.string(), attrs.string()),
        "local": attrs.bool(default = False),
    },
)

def buildrules_execution_platforms(name, linux_x86_64, isa_platforms = {}, visibility = None):
    """`isa_platforms`: REAPI `ISA` value (`x86-64-v3`) -> the execution platform of that level (platforms/BUCK `exec_<id>`).

    Remote unless `[buildrules_re] mode = local` (the module doc)."""
    if _mode() == "local":
        _refuse_local_beside_remote("linux_x86_64_properties")
    _exec_platforms(
        name = name,
        linux_x86_64 = linux_x86_64,
        isa_platforms = isa_platforms,
        properties = _properties("linux_x86_64_properties") if _mode() == "remote" else {},
        local = _mode() == "local",
        visibility = visibility,
    )
