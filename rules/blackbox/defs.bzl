"""Black-box tests: packages put onto a base image, then a driver run in it, as one `buck2 test` target that runs on the farm (README.md).

`blackbox_test(name, image, packages, driver)`: the image by digest, the packages (the service under test and every fake the test wants, each a pinned
download or a package built in the same build), and the driver, the program run once the packages are on the image. The run is `blackbox_run run`
(run.zig): it checks every pinned package, unpacks each package's files over the job's root in the order given, and runs the driver with that root as its
one argument. Starting the service and the fakes, pointing one at the other, driving them and stopping them is the driver's. The test is the driver's
status: a driver that fails is a red `buck2 test`.

The test carries its own executor (`test_executor`): the workers' property set (`[buildrules_re] linux_x86_64_properties`, every key, since an
executor's properties replace the platform's) with `container-image` set to `image`, and the runner requires to be a farm job that received that image
(farm.zig) and prints the job's action digest. It runs on a farm and nowhere else: in local mode the run fails, saying it is not a farm job. `buck2
build` of the target runs nothing (a test target has no output); a check calls `buck2 test`.

`farm_probe_test`: the toy that proved the mechanism. It passes only as a farm job whose frontend received exactly the workers' property set.
"""

load("@buildrules//rules:platforms.bzl", "linux_x86_64_worker_properties", "worker_properties_missing")
load("@buildrules//rules/core:pinned_file.bzl", "pinned_file")
load(":checks.bzl", "candidate_keys", "check_candidate", "check_image", "check_pin", "executor_properties")

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

def _impl(ctx):
    who = str(ctx.label.raw_target())
    if ctx.attrs.remote and not ctx.attrs.properties:
        fail(worker_properties_missing(who))
    # The farm job's root is the image's, which the job may write: the packages are put there, at the paths they name.
    args = [ctx.attrs._runner[RunInfo], "run", "--farm", "--image", ctx.attrs.image, "--root", "/"]
    for dep, pin in zip(ctx.attrs.packages, ctx.attrs.pins):
        args += ["--package", dep[DefaultInfo].default_outputs[0]]
        if pin:
            sha256, size = pin.split(":")
            args += ["--sha256", sha256, "--size", size]
    args += ["--driver", ctx.attrs.driver[RunInfo]]
    return [
        DefaultInfo(),
        _test_info(cmd_args(args), ["test", "blackbox"], ctx.attrs.properties if ctx.attrs.remote else None),
    ]

_blackbox_test = rule(
    impl = _impl,
    attrs = {
        "driver": attrs.dep(providers = [RunInfo]),
        "image": attrs.string(),
        # The packages in the order they are put onto the image, and beside each its pin (`<sha256>:<size>`, checked again by the runner), or "" for a
        # package built in the same build.
        "packages": attrs.list(attrs.dep()),
        "pins": attrs.list(attrs.string()),
        "properties": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "remote": attrs.bool(),
        "_runner": attrs.exec_dep(default = "buildrules//rules/blackbox:blackbox_run", providers = [RunInfo]),
    },
)

def blackbox_package(who, package, refuse = fail, config = None):
    """One package of a blackbox test: a pin `{"url": ..., "sha256": ..., "size": ...}`, with an optional `"candidate": NAME` naming the
    `-c blackbox.<NAME>_url/_sha256/_size` keys a release passes the package it is about to publish by (they replace the pin when given), or the label
    of a target whose output is the package. `config` reads a `[blackbox]` key (None: the root cell's configuration; the tests pass a table). Returns
    struct(pin = struct(url, sha256, size) or None, target = label or None)."""
    if type(package) == "string":
        if not (package.startswith(":") or "//" in package):
            refuse("{}: the package {} is neither a pin {{\"url\", \"sha256\", \"size\"}} nor a target label".format(who, repr(package)))
        return struct(pin = None, target = package)
    keys = sorted([k for k in (package.keys() if type(package) == "dict" else []) if k != "candidate"])
    if type(package) != "dict" or keys != ["sha256", "size", "url"]:
        refuse("{}: a package must be a pin with the keys url, sha256 and size (and, if a release passes its own, candidate), or a target label; got {}".format(who, repr(package)))
        return struct(pin = None, target = None)
    candidate = package.get("candidate")
    if candidate != None:
        read = config or (lambda key: read_root_config("blackbox", key, None))
        pin = check_candidate(who, candidate, [read(k) for k in candidate_keys(candidate)], refuse = refuse)
        if pin != None:
            return struct(pin = pin, target = None)
    check_pin(who, "a package", package["url"], package["sha256"], package["size"], refuse = refuse)
    return struct(pin = struct(url = package["url"], sha256 = package["sha256"], size = package["size"]), target = None)

def blackbox_test(name, image, packages, driver, visibility = None):
    """A `buck2 test` target that puts `packages` onto `image` and runs `driver` in it, on the farm (the module doc, README.md). `image` is by digest; each
    package is a pin (with an optional `candidate`) or a target label (`blackbox_package`); `driver` is a binary target, run with the root the packages
    were put onto as its one argument, and the test is its status."""
    who = "//{}:{}".format(native.package_name(), name)
    check_image(who, image)
    if type(packages) != "list" or not packages:
        fail("{}: `packages` must be a non-empty list: the service under test and the fakes the test wants".format(who))
    deps = []
    pins = []
    for i, package in enumerate(packages):
        chosen = blackbox_package(who, package)
        if chosen.pin != None:
            download = "{}.package{}".format(name, i)
            pinned_file(name = download, url = chosen.pin.url, sha256 = chosen.pin.sha256, size_bytes = chosen.pin.size)
            deps.append(":" + download)
            pins.append("{}:{}".format(chosen.pin.sha256, chosen.pin.size))
        else:
            deps.append(chosen.target)
            pins.append("")
    props = linux_x86_64_worker_properties()
    _blackbox_test(
        name = name,
        image = image,
        packages = deps,
        pins = pins,
        driver = driver,
        properties = executor_properties(props, image) if props else {},
        remote = props != None,
        visibility = visibility,
    )
