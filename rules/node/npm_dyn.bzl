"""PROTOTYPE: node_modules from a package-lock.json alone, with no table of hashes.

    npm_modules_dyn(name, lock)

The lockfile's own `resolved` URL and `integrity` (`sha512-<base64>`) are the only inputs. Two targets are declared:

    :<name>.tarballs   one `npm_fetch` action per locked tarball, declared by a `dynamic_output` that reads the lockfile.
                       The action's command line is {fetch_tool, --url, --sri, --out, --allow-host...} and it has NO input
                       files, so its action key is a function of those alone: a remote action cache serves its output to any
                       worker and any cold daemon without running it again. `fetch_tool` publishes the bytes only when their
                       sha512 is the stated one (exit 3 and no file otherwise).
    :<name>            the unpack of every tarball (`node_tools unpack`, which checks the sha512 again) and the tree.

`buildrules.url_map` is read here, when the BUCK file is evaluated, and passed as an attribute: `read_config` is not available
inside a `dynamic_output` lambda.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")

_OS = "linux"
_CPU = "x64"
_LIBC = "glibc"

_SRI = "sha512-"

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

def _name_of(path):
    """`node_modules/a/node_modules/@s/b` -> `@s/b`."""
    i = path.rfind("node_modules/")
    return path[i + len("node_modules/"):]

def _host_of(url):
    for scheme in ["https://", "http://"]:
        if url.startswith(scheme):
            rest = url[len(scheme):]
            end = len(rest)
            for c in ["/", "?", "#"]:
                j = rest.find(c)
                if j >= 0 and j < end:
                    end = j
            auth = rest[:end]
            if "@" in auth:
                return None
            return auth.split(":")[0].lower()
    return None

def _map_url(pairs, url):
    for src, dst in pairs:
        if url.startswith(src):
            return dst + url[len(src):]
    return url

def locked_packages(lock, allow_hosts, url_map, where, allow_data = False):
    """{key: {name, version, url, sri, dir}} for the packages of a parsed lockfile this platform installs.

    Refuses, with the fix in the message, an entry that has no `resolved` URL or no sha512 `integrity`, or whose host is not allowed."""
    if lock.get("lockfileVersion") != 3:
        fail("{}: lockfileVersion is {}; this prototype reads lockfileVersion 3".format(where, lock.get("lockfileVersion")))
    out = {}
    for path, row in lock.get("packages", {}).items():
        if path == "":
            continue
        if row.get("link"):
            continue
        if not (_platform_ok(row, "os", _OS) and _platform_ok(row, "cpu", _CPU) and _platform_ok(row, "libc", _LIBC)):
            continue
        name = _name_of(path)
        version = row.get("version", "")
        resolved = row.get("resolved")
        sri = row.get("integrity", "")
        what = "{} ({}@{})".format(path, name, version)
        if not resolved:
            fail("{}: {} has no `resolved` URL (a workspace or file dependency?): buildrules fetches registry tarballs only".format(where, what))
        if not sri.startswith(_SRI) or len(sri) != len(_SRI) + 88:
            fail("{}: {} has integrity `{}`, not a sha512 SRI string: run `npm install --package-lock-only` with npm 7 or later".format(where, what, sri))
        host = _host_of(resolved)
        if allow_data and resolved.startswith("data:"):
            pass
        elif host == None or host not in allow_hosts:
            fail("{}: {} is resolved from `{}`, whose host is not in allow_hosts {}: a lockfile entry can name any URL, so the hosts are listed in the BUCK file".format(where, what, resolved, allow_hosts))
        key = name + "@" + version
        if key in out and out[key]["sri"] != sri:
            fail("{}: {} appears with two different integrity strings".format(where, key))
        out[key] = {"name": name, "version": version, "url": _map_url(url_map, resolved), "resolved": resolved, "sri": sri}
    return out

def _file(sri):
    """A file name for an integrity: its base64 with the characters a path cannot hold replaced (one to one)."""
    return sri[len(_SRI):].replace("/", "_").replace("+", "-").replace("=", "") + ".tgz"

# ---- the fetch actions ---------------------------------------------------------------------------

def _tarballs_impl(ctx):
    where = str(ctx.label.raw_target())
    # A static path (not content-based): the unpack of one package names its tarball as tarballs/<file>.tgz, and that path must not
    # change when ANOTHER package of the lock does.
    out = ctx.actions.declare_output("tarballs", dir = True, has_content_based_path = False)
    url_map = [tuple(p.split("=", 1)) for p in ctx.attrs.url_map]
    allow = ctx.attrs.allow_hosts
    fetch = ctx.attrs._fetch[RunInfo]

    def build(ctx, artifacts, outputs):
        lock = artifacts[ctx.attrs.lock].read_json()
        pkgs = locked_packages(lock, allow, url_map, where, ctx.attrs.allow_data)
        files = {}
        for key in sorted(pkgs):
            p = pkgs[key]
            fname = _file(p["sri"])
            if fname in files:
                continue
            tgz = ctx.actions.declare_output("t/" + fname)
            args = cmd_args(fetch, "--url", p["url"], "--sri", p["sri"], "--out", tgz.as_output())
            hosts = list(allow)

            # The host of a mirror is the machine's choice (buildrules.url_map), not the lockfile's: it is allowed for the mapped URL only.
            if p["url"] != p["resolved"] and _host_of(p["url"]):
                hosts.append(_host_of(p["url"]))
            for h in hosts:
                args.add("--allow-host", h)
            if ctx.attrs.allow_data:
                args.add("--allow-data", "true")
            ctx.actions.run(args, category = "npm_fetch", identifier = key)
            files[fname] = tgz
        ctx.actions.symlinked_dir(outputs[out], files)

    ctx.actions.dynamic_output(dynamic = [ctx.attrs.lock], inputs = [], outputs = [out.as_output()], f = build)
    return [DefaultInfo(default_output = out)]

_npm_tarballs = rule(
    impl = _tarballs_impl,
    doc = "One `npm_fetch` action per tarball of `lock`, in one directory of `<integrity>.tgz` files.",
    attrs = {
        "allow_data": attrs.bool(default = False),
        "allow_hosts": attrs.list(attrs.string()),
        "lock": attrs.source(),
        "url_map": attrs.list(attrs.string(), default = []),
        "_fetch": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/fetch:fetch_tool"),
    },
)

# ---- the tree ------------------------------------------------------------------------------------

def _modules_impl(ctx):
    where = str(ctx.label.raw_target())
    out = ctx.actions.declare_output("node_modules", dir = True)
    tarballs = ctx.attrs.tarballs[DefaultInfo].default_outputs[0]
    tools = ctx.attrs._tools[RunInfo]
    allow = ctx.attrs.allow_hosts

    def build(ctx, artifacts, outputs):
        lock = artifacts[ctx.attrs.lock].read_json()
        pkgs = locked_packages(lock, allow, [], where, ctx.attrs.allow_data)
        dirs = {}
        sri = {}
        for key in sorted(pkgs):
            p = pkgs[key]
            spec = ctx.actions.write_json(
                "unpack-" + _file(p["sri"]) + ".json",
                {"name": p["name"], "sri512": p["sri"], "tarball": tarballs.project(_file(p["sri"])), "version": p["version"]},
                with_inputs = True,
            )
            d = ctx.actions.declare_output("pkg/" + _file(p["sri"]) + ".d", dir = True)
            ctx.actions.run(cmd_args(tools, "unpack", spec, d.as_output()), category = "npm_unpack", identifier = key)
            dirs[key] = d
            sri[key] = p["sri"]
        spec = ctx.actions.write_json(
            "tree.json",
            {"dirs": dirs, "lockfile": ctx.attrs.lock, "sri512": sri},
            with_inputs = True,
        )
        ctx.actions.run(cmd_args(tools, "tree", spec, outputs[out].as_output()), category = "npm_tree")

    ctx.actions.dynamic_output(dynamic = [ctx.attrs.lock], inputs = [], outputs = [out.as_output()], f = build)
    return [DefaultInfo(default_output = out)]

_npm_modules_dyn = rule(
    impl = _modules_impl,
    doc = "node_modules from `lock` and the tarballs of `tarballs`: one `npm_unpack` per package, then one `npm_tree`.",
    attrs = {
        "allow_data": attrs.bool(default = False),
        "allow_hosts": attrs.list(attrs.string()),
        "lock": attrs.source(),
        "tarballs": attrs.dep(),
        "_tools": attrs.exec_dep(providers = [RunInfo], default = "buildrules//rules/node:node_tools"),
    },
)

def npm_modules_dyn(name, lock = "package-lock.json", allow_hosts = ["registry.npmjs.org"], allow_data = False, visibility = None, **kwargs):
    """node_modules from `lock` only. `allow_hosts`: the hosts a `resolved` URL may name; a mirror host is added by `buildrules.url_map` itself."""
    pairs = []
    for pair in read_config("buildrules", "url_map", "").split():
        if "=" not in pair:
            fail("buildrules.url_map: `{}` is not <from-prefix>=<to-prefix>".format(pair))
        pairs.append(pair)
    kwargs.setdefault("exec_compatible_with", LINUX_X86_64)

    # The fetch actions reach a registry, so they run on the network-egress platform (platforms/BUCK). The data: test seam needs no network.
    fetch_kwargs = dict(kwargs)
    if not allow_data:
        fetch_kwargs["exec_compatible_with"] = LINUX_X86_64 + ["buildrules//platforms:exec_net_egress"]
    _npm_tarballs(
        name = name + ".tarballs",
        lock = lock,
        allow_hosts = allow_hosts,
        allow_data = allow_data,
        url_map = pairs,
        visibility = visibility,
        **fetch_kwargs
    )
    _npm_modules_dyn(
        name = name,
        lock = lock,
        allow_hosts = allow_hosts,
        allow_data = allow_data,
        tarballs = ":" + name + ".tarballs",
        visibility = visibility,
        **kwargs
    )
