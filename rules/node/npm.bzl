"""The front door of an npm package: `npm_package(path = ".")`.

A directory with a package.json and a package-lock.json gets its Buck2 targets from npm's own files and one generated table,
with no hand-written rules:

    # service/api/BUCK
    load(":buildrules.bzl", "npm_package")      # written by `buildrules npm sync`: binds the table below
    npm_package(path = ".")

Starlark cannot read JSON files, so `buildrules npm sync` reads package.json and package-lock.json and bakes what the macro
needs into `buildrules.lock.bzl`: the package's scripts and policy, the sha256 of both files, and every locked tarball with
the url, the sha512 integrity the lockfile states, and the sha256 and size Buck2 keys the download on. A table that no longer
matches the two files is red (`:check`), never silently used.

Targets of a package (a step exists when the package has the script, else building it fails with the reason):

    :node_modules  the tree `npm ci --ignore-scripts` would make, from the pinned tarballs: one cached action per package
                   (`:modules.npm-<name>_at_<version>`: download, sha512 check, unpack), then one cheap assembly that
                   copies them to their lockfile paths and links `.bin`. No install script runs, nothing is fetched at build time.
    :typecheck :lint :test    the package's script of that name, run by the pinned node in the tree (a pass marker)
    :build         the "build" script; its output is the directory named by "dist" in the policy (below), else a pass marker
    :dist          the policy's "dist" directory, the output of :build (same artifact); absent without that policy key
    :check         the table against package.json and package-lock.json; a validation of every step
    :<action>      one per action named in the "buildrules" key of package.json: its steps, chained

Policy only, in package.json under "buildrules" (any other key is refused by `sync`):

    "buildrules": {
      "steps":   {"typecheck": "tsc-check"},          # step -> script name (default: the step's own name)
      "actions": {"ci": ["typecheck", "test", "build"]},
      "dist":    "dist"                               # the directory the build script writes
    }

A step runs `pre<script>`, `<script>` and `post<script>` (as `npm run` does) with the shell's job done by node_tools: commands
joined by `&&`, quotes and leading NAME=value are understood; a pipe, redirection, `;`, `$`, glob or `npm`/`npx` is refused with
the fix. A policy edit re-runs `:check` and a small normalizing action; the steps read package.json without its "buildrules"
key, so they keep their cache keys.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")
load(":checks.bzl", "check_action", "check_package_path", "check_same_packages", "check_srcs_without_package_json", "check_table", "merge_staged")
load(":modules.bzl", "NodeModulesInfo", "node_tree_build", "node_tree_test")
load(":pins.bzl", "NODE")

_STEPS = ["typecheck", "lint", "test", "build"]

# `buildrules npm sync` writes these (rules/node/README or docs/contract.md, "npm"); the macro refuses anything else.
_SCHEMA = 1

# What the rules lay out for: the platform of the one execution platform (platform.zig says the same).
_OS = "linux"
_CPU = "x64"
_LIBC = "glibc"

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _file_name(key):
    return "modules.npm-" + key.replace("@", "_at_").replace("/", "__")

def _linux(kwargs):
    if "exec_compatible_with" not in kwargs:
        kwargs["exec_compatible_with"] = LINUX_X86_64
    return kwargs

# ---- one package: download, check, unpack -------------------------------------------------------

def _unpack_impl(ctx):
    tgz = ctx.actions.declare_output("package.tgz", has_content_based_path = False)
    ctx.actions.download_file(tgz.as_output(), ctx.attrs.url, sha256 = ctx.attrs.sha256, size_bytes = ctx.attrs.size_bytes)
    spec = ctx.actions.write_json(
        "spec.json",
        {"name": ctx.attrs.pkg, "sri512": ctx.attrs.sri512, "tarball": tgz, "version": ctx.attrs.version},
        with_inputs = True,
    )
    out = ctx.actions.declare_output("package", dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs._tools[RunInfo], "unpack", spec, out.as_output()),
        category = "npm_unpack",
        identifier = "{}@{}".format(ctx.attrs.pkg, ctx.attrs.version),
    )
    return [DefaultInfo(default_output = out)]

_npm_unpack = rule(
    impl = _unpack_impl,
    doc = "One locked npm tarball: downloaded (sha256 and size, which Buck2 keys the CAS on), its sha512 checked against `sri512` (the integrity the lockfile states), unpacked as npm does, and its package.json required to state `pkg` and `version`. The action's key holds this package only, so a bump of another package does not re-run it.",
    attrs = {
        "pkg": attrs.string(),
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "sri512": attrs.string(),
        "url": attrs.string(),
        "version": attrs.string(),
        "_tools": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/node:node_tools"),
    },
)

# ---- the tree ------------------------------------------------------------------------------------

def _tree_impl(ctx):
    where = str(ctx.label.raw_target())
    check_same_packages(where, "packages and sri512", ctx.attrs.packages.keys(), ctx.attrs.sri512.keys())
    spec = ctx.actions.write_json(
        "spec.json",
        {
            "dirs": {k: _out(v) for k, v in ctx.attrs.packages.items()},
            "lockfile": ctx.attrs.lockfile,
            "sri512": ctx.attrs.sri512,
        },
        with_inputs = True,
    )
    out = ctx.actions.declare_output("node_modules", dir = True)
    ctx.actions.run(cmd_args(ctx.attrs._tools[RunInfo], "tree", spec, out.as_output()), category = "npm_tree")
    return [DefaultInfo(default_output = out), NodeModulesInfo(dir = out)]

_npm_tree = rule(
    impl = _tree_impl,
    doc = "node_modules laid out from `lockfile` (lockfileVersion 3) and the unpacked packages of `packages` ({`name@version`: a `_npm_unpack` target}): each is copied to every path the lockfile gives it (nested node_modules included), `.bin` links are made, optional packages for another os or cpu are skipped. Copies and links only: the checks were made per package.",
    attrs = {
        "lockfile": attrs.source(),
        "packages": attrs.dict(attrs.string(), attrs.dep()),
        "sri512": attrs.dict(attrs.string(), attrs.string()),
        "_tools": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/node:node_tools"),
    },
)

# ---- check ---------------------------------------------------------------------------------------

def _check_impl(ctx):
    spec = ctx.actions.write_json(
        "spec.json",
        {
            "lockfile": ctx.attrs.lockfile,
            "lockfileSha256": ctx.attrs.lockfile_sha256,
            "packageJson": ctx.attrs.package_json,
            "packageJsonSha256": ctx.attrs.package_json_sha256,
            "table": ctx.attrs.table,
        },
        with_inputs = True,
    )
    out = ctx.actions.declare_output("table_in_sync")
    ctx.actions.run(cmd_args(ctx.attrs._tools[RunInfo], "check", spec, out.as_output()), category = "npm_table_check")
    return [DefaultInfo(default_output = out)]

_npm_check = rule(
    impl = _check_impl,
    doc = "Fails unless the sha256 of package.json and package-lock.json are the ones the table was made from and the lockfile's tarballs are exactly the table's (same integrity).",
    attrs = {
        "lockfile": attrs.source(),
        "lockfile_sha256": attrs.string(),
        "package_json": attrs.source(),
        "package_json_sha256": attrs.string(),
        "table": attrs.dict(attrs.string(), attrs.string()),
        "_tools": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/node:node_tools"),
    },
)

# package.json without the "buildrules" key, as the steps see it.
def _manifest_impl(ctx):
    out = ctx.actions.declare_output("package.json")
    ctx.actions.run(cmd_args(ctx.attrs._tools[RunInfo], "manifest", ctx.attrs.src, out.as_output()), category = "npm_manifest")
    return [DefaultInfo(default_output = out)]

_manifest = rule(
    impl = _manifest_impl,
    doc = "package.json re-written without its top-level \"buildrules\" key (policy), so that the steps' cache keys do not depend on it.",
    attrs = {
        "src": attrs.source(),
        "_tools": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/node:node_tools"),
    },
)

# ---- steps and actions ---------------------------------------------------------------------------

def _step_impl(ctx):
    outs = []
    for d in ctx.attrs.deps:
        outs += d[DefaultInfo].default_outputs
    info = [DefaultInfo(default_outputs = outs)]
    if ctx.attrs.check:
        info.append(ValidationInfo(validations = [
            ValidationSpec(name = "npm_table_in_sync", validation_result = _out(ctx.attrs.check)),
        ]))
    return info

_step = rule(
    impl = _step_impl,
    attrs = {
        "check": attrs.option(attrs.dep(), default = None),
        "deps": attrs.list(attrs.dep()),
    },
)

def _refuse_impl(ctx):
    fail("{}: {}".format(ctx.label, ctx.attrs.why))

# A target the package has no script for fails when built by name; a wildcard skips it as incompatible.
_refuse = rule(impl = _refuse_impl, attrs = {"why": attrs.string()})

def _platform_ok(row, field, current):
    lst = row.get(field)
    if not lst:
        return True
    allowed_any = False
    allowed = False
    for s in lst:
        if s.startswith("!"):
            if s[1:] == current:
                return False
        else:
            allowed_any = True
            if s == current:
                allowed = True
    return (not allowed_any) or allowed

def _script_of(scripts, name):
    """npm run's pre/post hooks around a script, `&&`-joined."""
    parts = []
    for n in ["pre" + name, name, "post" + name]:
        if n in scripts:
            parts.append(scripts[n])
    return " && ".join(parts)

def npm_package(
        path = ".",
        table = None,
        node = None,
        srcs = None,
        exclude = [],
        data = {},
        step_data = {},
        step_tools = {},
        step_env = {},
        visibility = ["PUBLIC"]):
    """Declares the targets of one npm package (see the module comment).

    Args:
        path: the package directory relative to the BUCK file calling this: `.` (v0: the BUCK file sits next to package.json).
        table: the generated table (`SCHEMA`, `NODE`, `PACKAGE_JSON_SHA256`, `PACKAGE_LOCK_SHA256`, `PACKAGE`, `NPM`); bound by
            the generated `buildrules.bzl`, so the call is `npm_package(path = ".")`.
        node: the node_dist target the steps run (default `buildrules//rules/node:node`). A repository that loads these rules as
            an external cell passes its own, as the providers of one cell's rules are not another's (facebook/buck2#683).
        srcs: the package's files the steps read. Default: everything in the package except node_modules/, the policy's dist
            directory, build/, coverage/, the BUCK file, package-lock.json, the generated buildrules files and `exclude` (a list of globs).
        exclude: more globs to leave out of the default `srcs`.
        data: {dest: label} files from elsewhere in the repository, staged at `dest` (a path from the cell root) for every step.
        step_data, step_tools, step_env: the same for one step ({step: ...}); tools are {command name: executable label}.
        visibility: of the steps, :node_modules and :dist.
    """
    check_package_path(path)
    check_table(table, _SCHEMA, NODE["version"], node != None)
    pkg = table["PACKAGE"]
    policy = pkg.get("buildrules", {})
    scripts = pkg.get("scripts", {})
    here = native.package_name()
    node = node or "buildrules//rules/node:node"

    # 1. the tree: one unpack per locked tarball for this platform, then one assembly.
    npm = table["NPM"]
    packages = {}
    sri = {}
    for key in sorted(npm):
        row = npm[key]
        if not (_platform_ok(row, "os", _OS) and _platform_ok(row, "cpu", _CPU) and _platform_ok(row, "libc", _LIBC)):
            continue
        t = _file_name(key)
        _npm_unpack(
            name = t,
            pkg = row["name"],
            version = row["version"],
            url = row["url"],
            sha256 = row["sha256"],
            size_bytes = row["size"],
            sri512 = row["sri512"],
            **_linux({})
        )
        packages[key] = ":" + t
        sri[key] = row["sri512"]

    _npm_tree(
        name = "node_modules",
        lockfile = "package-lock.json",
        packages = packages,
        sri512 = sri,
        visibility = visibility,
        **_linux({})
    )

    # 2. :check
    _npm_check(
        name = "check",
        lockfile = "package-lock.json",
        lockfile_sha256 = table["PACKAGE_LOCK_SHA256"],
        package_json = "package.json",
        package_json_sha256 = table["PACKAGE_JSON_SHA256"],
        table = {k: npm[k]["sri512"] for k in npm},
        visibility = visibility,
        **_linux({})
    )
    _manifest(name = "package.json.steps", src = "package.json", **_linux({}))

    # 3. the steps
    dist = policy.get("dist")
    step_map = policy.get("steps", {})
    if srcs == None:
        skip = ["node_modules/**", "build/**", "coverage/**", "BUCK", "buildrules.bzl", "buildrules.lock.bzl", "package.json", "package-lock.json"] + list(exclude)
        if dist:
            skip.append(dist + "/**")
        srcs = native.glob(["**"], exclude = skip)
    else:
        check_srcs_without_package_json(srcs)
    base_data = merge_staged([data, {here + "/package.json" if here else "package.json": ":package.json.steps"}])

    ran = []
    for step in _STEPS:
        script_name = step_map.get(step, step)
        text = _script_of(scripts, script_name)
        if not text:
            _refuse(
                name = step,
                why = "package.json has no \"{}\" script (and no pre/post of it); add one, or name the script for this step under \"buildrules\": {{\"steps\": {{\"{}\": ...}}}}, then run `buildrules npm sync`".format(script_name, step),
                target_compatible_with = ["buildrules//platforms:not_implemented"],
                visibility = visibility,
            )
            continue
        run = step + ".run"
        kw = dict(
            modules = ":node_modules",
            node = node,
            script = text,
            srcs = srcs,
            data = merge_staged([base_data, step_data.get(step, {})]),
            env = step_env.get(step, {}),
            tools = step_tools.get(step, {}),
        )
        if step == "build":
            if dist:
                node_tree_build(name = run, out_dir = dist, **kw)
            else:
                node_tree_test(name = run, **kw)
        else:
            node_tree_test(name = run, **kw)
        _step(name = step, deps = [":" + run], check = ":check", visibility = visibility)
        ran.append(step)
    if dist and "build" in ran:
        _step(name = "dist", deps = [":build.run"], check = ":check", visibility = visibility)
    else:
        _refuse(
            name = "dist",
            why = "the \"buildrules\" key of package.json names no \"dist\" directory (or the package has no build script): add \"dist\": \"<the directory the build script writes>\" and run `buildrules npm sync`",
            target_compatible_with = ["buildrules//platforms:not_implemented"],
            visibility = visibility,
        )

    # 4. actions: the policy's chains of steps
    for act, chain in policy.get("actions", {}).items():
        check_action(act, chain, _STEPS, ["dist", "check", "node_modules"])
        _step(name = act, deps = [":" + s for s in chain], visibility = visibility)
