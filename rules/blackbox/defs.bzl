"""Black-box tests: a released package run inside a named image against fakes, as one `buck2 test` target (README.md).

`blackbox_test(name, image, package, service, flags, fakes, fake_flags, driver, driver_flags, candidate)`: the target's run is the runner,
`blackbox_run run` (run.zig), with one argument list the rule builds. The runner unpacks the package, gives every fake and the service a loopback port of
its own, starts the fakes and waits until each takes a connection, starts the service's program by hand the same way, runs the driver, stops everything,
and prints every log when anything failed. The test passes when the driver exits 0 and the fakes and the service lived through it.

Where the run happens is the configuration's, never the target's:

  remote mode (a farm)   the test carries its own executor (`test_executor`): the workers' property set (`[buildrules_re] linux_x86_64_properties`, every
                         key, since an executor's properties replace the platform's) with `container-image` set to `image`. The runner also checks it is
                         a farm job that received that image (farm.zig) and prints the job's action digest.
  local mode             the run is on the machine running Buck2, and the runner starts itself inside `image` through docker: `-c blackbox.docker=<the
                         absolute path of the docker program>`. Without it the run fails, saying so: a test that names an image never runs outside it.

`farm_probe_test`: the toy that proved the mechanism. It passes only as a farm job whose frontend received exactly the workers' property set.
"""

load("@buildrules//rules:platforms.bzl", "linux_x86_64_worker_properties", "worker_properties_missing")
load("@buildrules//rules/core:pinned_file.bzl", "pinned_file")
load(":checks.bzl", "candidate_keys", "check_candidate", "check_flags", "check_image", "check_names", "check_pin", "check_service", "executor_properties")

def test_executor(properties):
    """The executor of a test whose run goes to the farm with exactly `properties` (Buck2 replaces the execution platform's executor with it: nothing of
    the platform's property set is kept), or None for the platform's own executor (local mode)."""
    if properties == None:
        return None
    return CommandExecutorConfig(
        local_enabled = False,
        remote_enabled = True,
        remote_execution_properties = properties,
        remote_execution_use_case = "buck2-default",
        # A test's result is never cached or uploaded (Buck2 turns the cache off for a test run); stated so the config says it too.
        remote_cache_enabled = False,
        allow_cache_uploads = False,
        use_limited_hybrid = False,
    )

def _test_info(command, labels, properties):
    return ExternalRunnerTestInfo(
        type = "custom",
        command = [command],
        labels = labels,
        # Both must be true for a test to run remotely (Buck2 forces it local otherwise); the open-source default of the first is true, stated anyway.
        run_from_project_root = True,
        use_project_relative_paths = True,
        default_executor = test_executor(properties),
    )

# ---- the toy ------------------------------------------------------------------------------------------------------------------------------------

def _probe_impl(ctx):
    props = ctx.attrs.properties
    if ctx.attrs.remote and not props:
        fail(worker_properties_missing(str(ctx.label.raw_target())))
    args = [ctx.attrs._runner[RunInfo], "probe"]
    for k, v in sorted(props.items()):
        args += ["--expect", "{}={}".format(k, v)]
    return [DefaultInfo(), _test_info(cmd_args(args), ["test", "farm"], props if ctx.attrs.remote else None)]

_farm_probe_test = rule(
    impl = _probe_impl,
    attrs = {
        "properties": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "remote": attrs.bool(),
        "_runner": attrs.exec_dep(default = "buildrules//rules/blackbox:blackbox_run", providers = [RunInfo]),
    },
)

def farm_probe_test(name, **kwargs):
    """A test that passes only as a farm job whose frontend received exactly the workers' property set; in local mode it runs on the machine and fails,
    saying it is not a farm job."""
    props = linux_x86_64_worker_properties()
    _farm_probe_test(name = name, properties = props or {}, remote = props != None, **kwargs)

# ---- blackbox_test ------------------------------------------------------------------------------------------------------------------------------

def _flag_args(option, flags):
    out = []
    for f in flags:
        out += [option, f]
    return out

def _impl(ctx):
    who = str(ctx.label.raw_target())
    if ctx.attrs.remote and not ctx.attrs.properties:
        fail(worker_properties_missing(who))
    names = list(ctx.attrs.fakes.keys()) + ["service"]
    check_flags(who, "the service", ctx.attrs.flags, names)
    check_flags(who, "the driver", ctx.attrs.driver_flags, names)
    for fake in ctx.attrs.fake_flags:
        if fake not in ctx.attrs.fakes:
            fail("{}: `fake_flags` names `{}`, which is not one of the fakes ({})".format(who, fake, ", ".join(sorted(ctx.attrs.fakes.keys())) or "none"))
    args = [ctx.attrs._runner[RunInfo], "run", "--image", ctx.attrs.image, "--package", ctx.attrs.package[DefaultInfo].default_outputs[0]]
    if ctx.attrs.package_sha256:
        args += ["--sha256", ctx.attrs.package_sha256, "--size", str(ctx.attrs.package_size)]
    args += ["--service", ctx.attrs.service] + _flag_args("--flag", ctx.attrs.flags)
    for fake, dep in sorted(ctx.attrs.fakes.items()):
        flags = ctx.attrs.fake_flags.get(fake, ["--listen", "{addr:" + fake + "}"])
        check_flags(who, "the fake `{}`".format(fake), flags, names)
        args += ["--fake", cmd_args(fake, "=", dep[RunInfo], delimiter = "")]
        args += _flag_args("--fake-flag", [fake + "=" + f for f in flags])
    args += ["--driver", ctx.attrs.driver[RunInfo]] + _flag_args("--driver-flag", ctx.attrs.driver_flags)
    args += ["--ready-s", str(ctx.attrs.ready_timeout_s)]
    if ctx.attrs.remote:
        args.append("--farm")
    else:
        # Empty when `[blackbox] docker` is not set: the runner refuses it and names the key.
        args += ["--docker", ctx.attrs.docker]
    return [
        DefaultInfo(),
        _test_info(cmd_args(args), ["test", "blackbox"] + ctx.attrs.labels, ctx.attrs.properties if ctx.attrs.remote else None),
    ]

_blackbox_test = rule(
    impl = _impl,
    attrs = {
        "docker": attrs.string(default = ""),
        "driver": attrs.dep(providers = [RunInfo]),
        "driver_flags": attrs.list(attrs.string(), default = []),
        "fake_flags": attrs.dict(attrs.string(), attrs.list(attrs.string()), default = {}),
        "fakes": attrs.dict(attrs.string(), attrs.dep(providers = [RunInfo]), default = {}),
        "flags": attrs.list(attrs.string(), default = []),
        "image": attrs.string(),
        "labels": attrs.list(attrs.string(), default = []),
        # The package: the pinned download (its sha256 and size are checked again by the runner) or a package built in the same build (both empty).
        "package": attrs.dep(),
        "package_sha256": attrs.string(default = ""),
        "package_size": attrs.int(default = 0),
        "properties": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "ready_timeout_s": attrs.int(default = 60),
        "remote": attrs.bool(),
        "service": attrs.string(),
        "_runner": attrs.exec_dep(default = "buildrules//rules/blackbox:blackbox_run", providers = [RunInfo]),
    },
)

def blackbox_package(who, package, candidate = None, refuse = fail, config = None):
    """What a blackbox test runs: the candidate the caller passed (`-c blackbox.<candidate>_url/_sha256/_size`), else `package`, which is a pin
    `{"url": ..., "sha256": ..., "size": ...}` or the label of a target whose output is the package. `config` reads a `[blackbox]` key (None: the root
    cell's configuration; the tests pass a table). Returns struct(pin = struct(url, sha256, size) or None, target = label or None)."""
    if candidate != None:
        read = config or (lambda key: read_root_config("blackbox", key, None))
        pin = check_candidate(who, candidate, [read(k) for k in candidate_keys(candidate)], refuse = refuse)
        if pin != None:
            return struct(pin = pin, target = None)
    if type(package) == "string":
        if not (package.startswith(":") or "//" in package):
            refuse("{}: `package` {} is neither a pin {{\"url\", \"sha256\", \"size\"}} nor a target label".format(who, repr(package)))
        return struct(pin = None, target = package)
    if type(package) != "dict" or sorted(package.keys()) != ["sha256", "size", "url"]:
        refuse("{}: `package` must be a pin with exactly the keys url, sha256 and size, or a target label; got {}".format(who, repr(package)))
        return struct(pin = None, target = None)
    check_pin(who, "`package`", package["url"], package["sha256"], package["size"], refuse = refuse)
    return struct(pin = struct(url = package["url"], sha256 = package["sha256"], size = package["size"]), target = None)

def blackbox_test(
        name,
        image,
        package,
        service,
        driver,
        flags = [],
        fakes = {},
        fake_flags = {},
        driver_flags = ["--service", "{addr:service}"],
        candidate = None,
        ready_timeout_s = 60,
        labels = [],
        visibility = None):
    """A `buck2 test` target that runs the program `service` (a path inside the package) of the released `package` inside `image`, with every outside
    address it is given (`flags`) pointing at a fake, and passes when `driver` does (README.md). `image` is by digest; `package` is a pin
    `{"url", "sha256", "size"}` (or a label of a package built in the same build); `candidate` names the `-c blackbox.<candidate>_url/_sha256/_size` keys
    a release passes the package it is about to publish by. `fakes` maps a name to a binary target; a fake's flags are `fake_flags[name]`, by default
    `--listen {addr:<name>}`."""
    who = "//{}:{}".format(native.package_name(), name)
    check_image(who, image)
    check_names(who, fakes.keys())
    check_service(who, service)
    if type(ready_timeout_s) != "int" or ready_timeout_s <= 0:
        fail("{}: `ready_timeout_s` must be a positive number of seconds".format(who))
    chosen = blackbox_package(who, package, candidate)
    if chosen.pin != None:
        pinned_file(name = name + ".package", url = chosen.pin.url, sha256 = chosen.pin.sha256, size_bytes = chosen.pin.size)
        package_attrs = dict(package = ":" + name + ".package", package_sha256 = chosen.pin.sha256, package_size = chosen.pin.size)
    else:
        package_attrs = dict(package = chosen.target)
    props = linux_x86_64_worker_properties()
    _blackbox_test(
        name = name,
        image = image,
        service = service,
        flags = flags,
        fakes = fakes,
        fake_flags = fake_flags,
        driver = driver,
        driver_flags = driver_flags,
        ready_timeout_s = ready_timeout_s,
        labels = labels,
        properties = executor_properties(props, image) if props else {},
        remote = props != None,
        docker = read_root_config("blackbox", "docker", "").strip(),
        visibility = visibility,
        **package_attrs
    )
