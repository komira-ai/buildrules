"""The Mojo toolchains, made from mopm's unit graphs (docs/contract.md, section 12).

buildrules has no Mojo pin of its own. The compiler, its two C++ runtime packages and the zig that links for it are whatever
mopm's unit graph says (`toolchain` of `mopm plan --unit-graph`); `buildrules mojo sync` copies that section into
toolchains/mojo_pins.bzl and `mojo_toolchains()` (one call of toolchains/BUCK) declares, for each Mojo version in it:

    pinned_file x4     the compiler package, libgcc, libstdcxx, the zig archive (URL, sha256, size from the graph)
    mojo_<v>_compiler  the compiler closure: conda_unpack of the three packages
    mojo_<v>_zig       the zig distribution unpacked
    mojo_<v>_cov_link  the zig directory of the coverage builds (rules/coverage)
    mojo_<v>           the toolchain: MojoToolchainInfo, naming the closure hash mopm computed

`v` is the version with `_` for `.`. The unit action assembles the directory `mopm unit build --toolchain` wants (rules/mojo/unit.bzl).
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:url_map.bzl", "mapped_url")
load("//rules/coverage:defs.bzl", "cov_link")
load("//rules/coverage/branch:llvm_branch.bzl", "RAW_PROFILE_VERSION", "cov_branch_toolchain", "llvm_branch_check", "llvm_branch_unpack")
load("//rules/pins:pins.bzl", "PINS")
load("//rules/zig:zig.bzl", "zig_dist")
load(":mojo.bzl", "mojo_closure_rule")
load(":providers.bzl", "MojoToolchainInfo")
load(":subdirs.bzl", "subdir_suffix")

# The members of the two runtime packages the compiler needs next to it (a worker supplies glibc and nothing else).
_RUNTIME_MEMBERS = {
    "libgcc": "lib/libgcc_s.so.1",
    "libstdcxx": "lib/libstdc++.so.6",
}

def _vname(version):
    return version.replace(".", "_")

def _impl(ctx):
    return [
        DefaultInfo(),
        MojoToolchainInfo(
            version = ctx.attrs.version,
            closure_sha256 = ctx.attrs.closure_sha256,
            cc_target = ctx.attrs.cc_target,
            facts = ctx.attrs.facts,
            compiler = ctx.attrs.compiler[DefaultInfo].default_outputs[0],
            zig = ctx.attrs.zig[DefaultInfo].default_outputs[0],
        ),
    ]

mojo_toolchain = rule(
    impl = _impl,
    attrs = {
        "cc_target": attrs.string(),
        "closure_sha256": attrs.string(),
        "compiler": attrs.dep(),
        "facts": attrs.dict(attrs.string(), attrs.any()),
        "version": attrs.string(),
        "zig": attrs.dep(),
    },
)

def _mojo_zig(v, archive, zig_url):
    """`mojo_<v>_zig`: the zig distribution of a toolchain, unpacked from its pinned archive."""
    zig_dist(
        name = "mojo_{}_zig".format(v),
        archive = archive,
        busybox = "buildrules//rules/pins:busybox",
        strip_prefix = zig_url.split("/")[-1][:-len(".tar.xz")],
        exec_compatible_with = LINUX_X86_64,
    )

def split_toolchain_table(table):
    """`(linux-64 rows, {subdir: {version: row}})` of `MOJO_TOOLCHAINS`: the key of a linux-64 row is the Mojo version, the key of another subdir's `<version>@<subdir>`."""
    base = {}
    others = {}
    for key, row in table.items():
        version, at, subdir = key.partition("@")
        if not at:
            base[key] = row
        else:
            others.setdefault(subdir, {})[version] = row
    return base, others

def mojo_toolchains(table = {}):
    """Declares the toolchain of every Mojo version of `table` (toolchains/mojo_pins.bzl: MOJO_TOOLCHAINS), and, for a key `<version>@<subdir>`, that of the subdir."""
    table, others = split_toolchain_table(table)
    mojo_subdir_toolchains(others)
    for version, row in sorted(table.items()):
        v = _vname(version)
        compiler = None
        libs = {}
        for c in row["components"]:
            fname = "mojo-{}-{}.conda".format(version, c["name"])
            pinned_file(name = fname, url = mapped_url(c["url"]), sha256 = c["sha256"], size_bytes = c["size"])
            if c["name"] == "mojo-compiler":
                compiler = ":" + fname
            elif c["name"] in _RUNTIME_MEMBERS:
                libs[_RUNTIME_MEMBERS[c["name"]]] = ":" + fname
            else:
                fail("mojo {}: the graph names a toolchain component {}, which buildrules does not know how to place".format(version, repr(c["name"])))
        if compiler == None or len(libs) != len(_RUNTIME_MEMBERS):
            fail("mojo {}: the graph's toolchain must hold mojo-compiler, libgcc and libstdcxx".format(version))
        zig_url = row["zig"]["url"]
        if not zig_url.endswith(".tar.xz"):
            fail("mojo {}: the graph's zig is {}, not a .tar.xz".format(version, zig_url))
        pinned_file(name = "mojo-{}-zig.tar.xz".format(version), url = mapped_url(zig_url), sha256 = row["zig"]["sha256"], size_bytes = row["zig"]["size"])
        mojo_closure_rule(
            name = "mojo_{}_compiler".format(v),
            libs = libs,
            package = compiler,
            unpacker = "buildrules//rules/mojo:conda_unpack",
            exec_compatible_with = LINUX_X86_64,
        )
        _mojo_zig(v, ":mojo-{}-zig.tar.xz".format(version), zig_url)
        # The link directory of this version's coverage builds: cov_zig and debug_relocate in front of this zig.
        cov_link(
            name = "mojo_{}_cov_link".format(v),
            zig = ":mojo_{}_zig".format(v),
            exec_compatible_with = LINUX_X86_64,
            visibility = ["PUBLIC"],
        )
        # The LLVM pieces of this version's branch coverage (rules/coverage/branch/README.md): its own lld (LLD 24, the LLVM the compiler is
        # built on: only it reads and writes the compiler's bitcode), unpacked from the pinned compiler package, next to the LLVM 23
        # llvm-profdata and profile runtime every version shares, and the checks that the pair agrees on the raw profile format.
        llvm_branch_unpack(
            name = "mojo_{}_lld24".format(v),
            exec_compatible_with = LINUX_X86_64,
            members = {
                "bin/lld": "mojo/bin/lld",
                "lib/libgcc_s.so.1": "libgcc/lib/libgcc_s.so.1",
                "lib/libstdc++.so.6": "libstdcxx/lib/libstdc++.so.6",
            },
            packages = {
                "libgcc": "buildrules//rules/pins:" + PINS["libgcc"]["name"],
                "libstdcxx": "buildrules//rules/pins:" + PINS["libstdcxx"]["name"],
                "mojo": compiler,
            },
        )
        llvm_branch_check(
            name = "mojo_{}_lld24_check".format(v),
            exec_compatible_with = LINUX_X86_64,
            lld = ":mojo_{}_lld24".format(v),
            mode = "lld",
            want = {"lld": "24"},
        )
        llvm_branch_check(
            name = "mojo_{}_raw_version_check".format(v),
            exec_compatible_with = LINUX_X86_64,
            fixtures = ["buildrules//rules/coverage/branch:profile_fixture.c"],
            lld = ":mojo_{}_lld24".format(v),
            mode = "raw_version",
            tools = "buildrules//rules/coverage/branch:llvm23",
            want = {
                "counts": "classify:2,3",
                "functions": "3",
                "raw": str(RAW_PROFILE_VERSION),
                "triple": row["cc_target"],
            },
        )
        cov_branch_toolchain(
            name = "mojo_{}_cov_branch".format(v),
            exec_compatible_with = LINUX_X86_64,
            checks = [
                ":mojo_{}_lld24_check".format(v),
                ":mojo_{}_raw_version_check".format(v),
                "buildrules//rules/coverage/branch:llvm23_check",
            ],
            lld = ":mojo_{}_lld24".format(v),
            tools = "buildrules//rules/coverage/branch:llvm23",
            visibility = ["PUBLIC"],
        )
        mojo_toolchain(
            name = "mojo_" + v,
            cc_target = row["cc_target"],
            closure_sha256 = row["closure_sha256"],
            compiler = ":mojo_{}_compiler".format(v),
            facts = row,
            version = version,
            zig = ":mojo_{}_zig".format(v),
            visibility = ["PUBLIC"],
        )

def mojo_subdir_toolchains(by_subdir = {}):
    """Declares the toolchain of every Mojo version for the subdirs other than linux-64 (the `<version>@<subdir>` rows of toolchains/mojo_pins.bzl: MOJO_TOOLCHAINS, as `{subdir: {version: row}}`).

    The same four pins and the same `mojo_<v>_<subdir>_compiler`, `mojo_<v>_<subdir>_zig` and `mojo_<v>_<subdir>` as the linux-64 toolchain (`_` for `-` in the
    subdir), made from the graph of that subdir: a package built for linux aarch64 or macOS arm64 is compiled and linked with the compiler and the zig mopm pinned
    for it (rules/mojo/subdirs.bzl). The coverage targets of a version (`_cov_link`, `_cov_branch`) exist for linux-64 only: coverage runs there.
    """
    for subdir, table in sorted(by_subdir.items()):
        for version, row in sorted(table.items()):
            v = "{}_{}".format(_vname(version), subdir_suffix(subdir))
            compiler = None
            libs = {}
            for c in row["components"]:
                fname = "mojo-{}-{}-{}.conda".format(version, subdir, c["name"])
                pinned_file(name = fname, url = mapped_url(c["url"]), sha256 = c["sha256"], size_bytes = c["size"])
                if c["name"] == "mojo-compiler":
                    compiler = ":" + fname
                elif c["name"] in _RUNTIME_MEMBERS:
                    libs[_RUNTIME_MEMBERS[c["name"]]] = ":" + fname
                else:
                    fail("mojo {} ({}): the graph names a toolchain component {}, which buildrules does not know how to place".format(version, subdir, repr(c["name"])))
            if compiler == None:
                fail("mojo {} ({}): the graph's toolchain must hold mojo-compiler".format(version, subdir))
            zig_url = row["zig"]["url"]
            if not zig_url.endswith(".tar.xz"):
                fail("mojo {} ({}): the graph's zig is {}, not a .tar.xz".format(version, subdir, zig_url))
            pinned_file(name = "mojo-{}-{}-zig.tar.xz".format(version, subdir), url = mapped_url(zig_url), sha256 = row["zig"]["sha256"], size_bytes = row["zig"]["size"])
            mojo_closure_rule(
                name = "mojo_{}_compiler".format(v),
                libs = libs,
                package = compiler,
                unpacker = "buildrules//rules/mojo:conda_unpack",
                exec_compatible_with = LINUX_X86_64,
            )
            _mojo_zig(v, ":mojo-{}-{}-zig.tar.xz".format(version, subdir), zig_url)
            mojo_toolchain(
                name = "mojo_" + v,
                cc_target = row["cc_target"],
                closure_sha256 = row["closure_sha256"],
                compiler = ":mojo_{}_compiler".format(v),
                facts = row,
                version = version,
                zig = ":mojo_{}_zig".format(v),
                visibility = ["PUBLIC"],
            )
