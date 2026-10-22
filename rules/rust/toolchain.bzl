"""The hermetic Rust toolchain: pinned downloads, unpacked and assembled by actions.

`rust_toolchains()` is the one call a consumer's toolchains/BUCK makes. It declares, in the
calling package: busybox, zig (+ its archive) and, for EVERY Rust version in `RUST_VERSIONS` (pins.bzl) plus the
user's `extra` versions (the generated `rust_pins.bzl`, from `buildrules-pins.toml`): the rustc, rust-std, cargo and
clippy pins, `sysroot_<v>`, `cargo_<v>`, `clippy_<v>` and `rust_<v>` (`v` = the version with `_` for `.`: `rust_1_85_0`).
`:rust`, `:sysroot`, `:cargo` and `:clippy` are aliases of the default version's (`RUST_DEFAULT`); the Rust rules
take `:rust` unless a platform or the table selects another (cargo.bzl).

Every tool an action runs is one of its inputs; nothing is searched on the worker's PATH.
The worker supplies glibc, libgcc_s.so.1 and libz.so.1 (rustc's own dependencies), a Linux
kernel, and nothing else; no host rustc, cargo or cc is read.
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load(":pins.bzl", "PINS", "RUST_DEFAULT", "RUST_TRIPLE", "RUST_VERSIONS", "ZIG_CC_TARGET", "ZIG_STRIP_PREFIX", "component", "vname")
load(":providers.bzl", "RustToolchainInfo")

# Perturbs every toolchain action key without changing any output (`-c buildrules.nonce=N`): a
# determinism probe that re-executes the unpacks and compiles on the farm, cache enabled.
_NONCE = read_config("buildrules", "nonce", "")
_ENV = {"BUILDRULES_NONCE": _NONCE}

def _file(dep):
    return dep[DefaultInfo].default_outputs[0]

# ---- zig -----------------------------------------------------------------------

def _zig_dist_impl(ctx):
    bb = _file(ctx.attrs.busybox)
    # The archive unpacks into a directory named `strip_prefix`: busybox tar extracts into
    # the parent of an output declared with that name; the toolchain is that directory.
    raw = ctx.actions.declare_output(ctx.attrs.strip_prefix, dir = True)
    ctx.actions.run(
        cmd_args(bb, "tar", "-xJf", _file(ctx.attrs.archive), "-C", cmd_args(raw.as_output(), parent = 1)),
        category = "zig_unpack",
        env = _ENV,
    )
    return [DefaultInfo(default_output = ctx.actions.copy_dir("zig", raw))]

zig_dist = rule(
    impl = _zig_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "strip_prefix": attrs.string(),
    },
)

def _zig_exe_impl(ctx):
    out = ctx.actions.declare_output(ctx.label.name)

    # `check run` (rules/check): zig starts in the action's working directory with the action's environment and a private scratch directory
    # (`$BUCK_SCRATCH_PATH/br`: made, emptied before and removed after) holding its two caches (`g`, `l`); HOME is the scratch directory itself.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._check_exe[RunInfo],
            "run",
            "--scratch",
            "br",
            "--dir",
            "ZIG_GLOBAL_CACHE_DIR=g",
            "--dir",
            "ZIG_LOCAL_CACHE_DIR=l",
            "--dir",
            "HOME=.",
            "--",
            cmd_args(_file(ctx.attrs.zig), "/zig", delimiter = ""),
            "build-exe",
            ctx.attrs.src,
            "-O",
            "ReleaseSafe",
            "-fstrip",
            "-target",
            "x86_64-linux-musl",
            cmd_args(out.as_output(), format = "-femit-bin={}"),
            "--name",
            "rustc_launch",
        ),
        category = "zig_exe",
        env = _ENV,
    )
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

zig_exe = rule(
    impl = _zig_exe_impl,
    attrs = {
        "src": attrs.source(),
        "zig": attrs.exec_dep(),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)

# ---- rustc, rust-std, cargo ------------------------------------------------------

_SYSROOT = """set -eu
BB="$1"; RUSTC="$2"; STD="$3"; OUT="$4"; TRIPLE="$5"; VER="$6"
T="$BUCK_SCRATCH_PATH/x"
"$BB" mkdir -p "$T" "$OUT"
"$BB" tar -xzf "$RUSTC" -C "$T"
"$BB" tar -xzf "$STD" -C "$T"
# bin/rustc, lib/*.so (rustc's own libraries), lib/rustlib/...
"$BB" cp -a "$T/rustc-$VER-$TRIPLE/rustc/." "$OUT/"
# the standard library for the one triple
"$BB" cp -a "$T/rust-std-$VER-$TRIPLE/rust-std-$TRIPLE/lib/." "$OUT/lib/"
"$BB" rm -rf "$OUT/share" "$OUT/etc" "$T"
# rustc_launch reads the version from here (which options this rustc knows).
echo "$VER" > "$OUT/.rustc_version"
"""

def _rust_sysroot_impl(ctx):
    out = ctx.actions.declare_output("sysroot", dir = True)
    bb = _file(ctx.attrs.busybox)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _SYSROOT, "sh", bb, _file(ctx.attrs.rustc), _file(ctx.attrs.rust_std), out.as_output(), ctx.attrs.triple, ctx.attrs.version),
        category = "rust_sysroot",
        env = _ENV,
    )
    return [DefaultInfo(default_output = out)]

rust_sysroot = rule(
    impl = _rust_sysroot_impl,
    attrs = {
        "busybox": attrs.dep(),
        "rust_std": attrs.dep(),
        "rustc": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
    },
)

_CARGO = """set -eu
BB="$1"; TGZ="$2"; OUT="$3"; TRIPLE="$4"; VER="$5"; WANT="$6"
T="$BUCK_SCRATCH_PATH/x"
"$BB" mkdir -p "$T" "$OUT"
"$BB" tar -xzf "$TGZ" -C "$T"
"$BB" cp -a "$T/cargo-$VER-$TRIPLE/cargo/." "$OUT/"
"$BB" rm -rf "$OUT/share" "$OUT/etc" "$T"
GOT=$("$OUT/bin/cargo" --version)
case "$GOT" in
    "$WANT"*) ;;
    *)
        echo "cargo_dist: pinned '$WANT' but cargo prints '$GOT'" >&2
        exit 1
        ;;
esac
"""

def _cargo_dist_impl(ctx):
    out = ctx.actions.declare_output("cargo", dir = True)
    bb = _file(ctx.attrs.busybox)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _CARGO, "sh", bb, _file(ctx.attrs.archive), out.as_output(), ctx.attrs.triple, ctx.attrs.version, ctx.attrs.version_line),
        category = "cargo_unpack",
        env = _ENV,
    )
    return [DefaultInfo(default_output = out)]

cargo_dist = rule(
    impl = _cargo_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
        "version_line": attrs.string(),
    },
)

_CLIPPY = """set -eu
BB="$1"; TGZ="$2"; OUT="$3"; TRIPLE="$4"; VER="$5"
T="$BUCK_SCRATCH_PATH/x"
"$BB" mkdir -p "$T" "$OUT"
"$BB" tar -xzf "$TGZ" -C "$T"
"$BB" cp -a "$T/clippy-$VER-$TRIPLE/clippy-preview/." "$OUT/"
"$BB" rm -rf "$OUT/share" "$T"
"""

def _clippy_dist_impl(ctx):
    out = ctx.actions.declare_output("clippy", dir = True)
    bb = _file(ctx.attrs.busybox)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _CLIPPY, "sh", bb, _file(ctx.attrs.archive), out.as_output(), ctx.attrs.triple, ctx.attrs.version),
        category = "clippy_unpack",
        env = _ENV,
    )
    return [DefaultInfo(default_output = out)]

clippy_dist = rule(
    impl = _clippy_dist_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
    },
)

_LLVM_TOOLS = """set -eu
BB="$1"; TGZ="$2"; OUT="$3"; TRIPLE="$4"; VER="$5"
T="$BUCK_SCRATCH_PATH/x"
"$BB" mkdir -p "$T" "$OUT"
"$BB" tar -xzf "$TGZ" -C "$T"
# lib/rustlib/<triple>/bin/llvm-objdump (and the rest) and the lib/libLLVM they load through $ORIGIN/../lib
"$BB" cp -a "$T/llvm-tools-$VER-$TRIPLE/llvm-tools-preview/." "$OUT/"
"$BB" rm -rf "$T"
"""

def _llvm_tools_impl(ctx):
    out = ctx.actions.declare_output("llvm_tools", dir = True)
    bb = _file(ctx.attrs.busybox)
    ctx.actions.run(
        cmd_args(bb, "sh", "-c", _LLVM_TOOLS, "sh", bb, _file(ctx.attrs.archive), out.as_output(), ctx.attrs.triple, ctx.attrs.version),
        category = "llvm_tools_unpack",
        env = _ENV,
    )
    return [DefaultInfo(default_output = out)]

llvm_tools_dist = rule(
    impl = _llvm_tools_impl,
    attrs = {
        "archive": attrs.dep(),
        "busybox": attrs.dep(),
        "triple": attrs.string(),
        "version": attrs.string(),
    },
)

# ---- the toolchain ---------------------------------------------------------------

def _rust_toolchain_impl(ctx):
    bb = _file(ctx.attrs.busybox)
    sysroot = _file(ctx.attrs.sysroot)
    ok = ctx.actions.declare_output("rustc_version_ok")

    # `check expect --prefix` (rules/check): `rustc --version` starts with `version_line` (the full pinned line for a version of RUST_VERSIONS and
    # `rustc <version> (` for one the user pinned); then, and only then, `ok` holds what it printed.
    ctx.actions.run(
        cmd_args(
            ctx.attrs._check_exe[RunInfo],
            "expect",
            "--prefix",
            "--name",
            "rust_toolchain",
            "--want",
            ctx.attrs.version_line,
            "--out",
            ok.as_output(),
            "--",
            cmd_args(sysroot, "/bin/rustc", delimiter = ""),
            "--version",
        ),
        category = "rustc_version",
        env = _ENV,
    )
    return [
        DefaultInfo(default_output = ok),
        RustToolchainInfo(
            busybox = bb,
            sysroot = sysroot,
            zig = _file(ctx.attrs.zig),
            cc_target = ctx.attrs.cc_target,
            launcher = _file(ctx.attrs.launcher),
            bs_runner = _file(ctx.attrs.bs_runner),
            version_ok = ok,
            version = ctx.attrs.version,
            clippy = _file(ctx.attrs.clippy),
        ),
    ]

rust_toolchain = rule(
    impl = _rust_toolchain_impl,
    attrs = {
        "bs_runner": attrs.exec_dep(default = "buildrules//rules/rust:bs_runner"),
        "busybox": attrs.exec_dep(),
        "cc_target": attrs.string(),
        "clippy": attrs.exec_dep(),
        "launcher": attrs.exec_dep(default = "buildrules//rules/rust:rustc_launch"),
        "sysroot": attrs.exec_dep(),
        "version": attrs.string(),
        "version_line": attrs.string(),
        "zig": attrs.exec_dep(),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)

def rust_toolchains(extra = {}):
    """Declares the pinned downloads and the toolchains in the calling package (the `toolchains` cell).

    Args:
        extra: version -> row, the user's own pins (the `EXTRA_RUST_VERSIONS` of the generated `rust_pins.bzl`): `date` and,
            per component `rustc`, `rust_std`, `cargo`, `clippy`, `{"sha256", "size"}`. A version already in `RUST_VERSIONS` is
            refused: the table's hashes are the reviewed ones.
    """
    for role in ["busybox", "zig"]:
        p = PINS[role]
        pinned_file(
            name = role + "_pin",
            out = p["name"],
            url = p["url"],
            sha256 = p["sha256"],
            size_bytes = p["size"],
            executable = (role == "busybox"),
            visibility = ["PUBLIC"],
        )
    zig_dist(
        name = "zig",
        archive = ":zig_pin",
        busybox = ":busybox_pin",
        strip_prefix = ZIG_STRIP_PREFIX,
        visibility = ["PUBLIC"],
    )
    versions = dict(RUST_VERSIONS)
    for v, row in extra.items():
        if v in RUST_VERSIONS:
            fail("buildrules-pins.toml pins rust {}, which buildrules already pins (rules/rust/pins.bzl): remove it".format(v))
        for k in ["rustc", "rust_std", "cargo", "clippy"]:
            if k not in row:
                fail("rust_pins.bzl: version {} has no `{}`; run `buildrules sync`".format(v, k))
        versions[v] = row
    for v, row in versions.items():
        n = vname(v)
        for role in ["rustc", "rust_std", "cargo", "clippy"]:
            p = component(v, row, role)
            pinned_file(
                name = "{}_pin_{}".format(role, n),
                out = p["name"],
                url = p["url"],
                sha256 = p["sha256"],
                size_bytes = p["size"],
                visibility = ["PUBLIC"],
            )
        rust_sysroot(
            name = "sysroot_" + n,
            busybox = ":busybox_pin",
            rustc = ":rustc_pin_" + n,
            rust_std = ":rust_std_pin_" + n,
            triple = RUST_TRIPLE,
            version = v,
            visibility = ["PUBLIC"],
        )
        cargo_dist(
            name = "cargo_" + n,
            archive = ":cargo_pin_" + n,
            busybox = ":busybox_pin",
            triple = RUST_TRIPLE,
            version = v,
            version_line = "cargo {} (".format(v),
            visibility = ["PUBLIC"],
        )
        clippy_dist(
            name = "clippy_" + n,
            archive = ":clippy_pin_" + n,
            busybox = ":busybox_pin",
            triple = RUST_TRIPLE,
            version = v,
            visibility = ["PUBLIC"],
        )
        if "llvm_tools" in row:
            p = component(v, row, "llvm_tools")
            pinned_file(
                name = "llvm_tools_pin_" + n,
                out = p["name"],
                url = p["url"],
                sha256 = p["sha256"],
                size_bytes = p["size"],
                visibility = ["PUBLIC"],
            )
            llvm_tools_dist(
                name = "llvm_tools_" + n,
                archive = ":llvm_tools_pin_" + n,
                busybox = ":busybox_pin",
                triple = RUST_TRIPLE,
                version = v,
                visibility = ["PUBLIC"],
            )
        rust_toolchain(
            name = "rust_" + n,
            clippy = ":clippy_" + n,
            busybox = ":busybox_pin",
            sysroot = ":sysroot_" + n,
            zig = ":zig",
            cc_target = ZIG_CC_TARGET,
            version = v,
            version_line = "rustc {} (".format(v),
            visibility = ["PUBLIC"],
        )
    d = vname(RUST_DEFAULT)
    for name in ["rust", "sysroot", "cargo", "clippy"] + (["llvm_tools"] if "llvm_tools" in versions[RUST_DEFAULT] else []):
        native.alias(name = name, actual = ":{}_{}".format(name, d), visibility = ["PUBLIC"])
