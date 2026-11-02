"""The pinned zig of the tool execution platform: which archive `:zig` and `:zig_next` unpack (rules/pins/BUCK)."""

load(":hosts.bzl", "HOST_PINS")
load(":pins.bzl", "PINS", "strip_prefix")

# The most decompressed bytes (the tar stream, headers and padding included) each linux x86_64 distribution may hold: the size its tarball decompresses to, with about 30% to spare
# (400 MiB for zig 0.12.0, 448 MiB for zig 0.15.2). An archive that outgrows its limit makes its unpacking action fail, which //ci:all builds.
_MAX_OUTPUT = {"zig": 400 * 1024 * 1024, "zig_next": 448 * 1024 * 1024}

# The macOS archive of a Mac that runs Buck2 itself has no limit of its own: it gets the larger limit, which is also the one of the zig of a Mojo toolchain (rules/mojo/toolchain.bzl).
_MAX_OUTPUT_MAC = 512 * 1024 * 1024

def tool_zig(role, local_mac):
    """The `archive`, `strip_prefix` and the checks (`sha256`, `size_bytes`, `max_output`) of the `zig_dist` of the zig `role` (`zig`, `zig_next`). On a farm, and on any Linux machine, the
    linux x86_64 archive, as it always was. On a Mac that runs Buck2 itself (`local_mac`) the macOS archive of the same release (hosts.bzl). Either is unpacked by the pinned `unpack`."""
    if local_mac:
        pin = HOST_PINS["macos-aarch64"][role]
        return {
            "archive": ":macos-aarch64__" + pin["name"],
            "max_output": _MAX_OUTPUT_MAC,
            "sha256": pin["sha256"],
            "size_bytes": pin["size"],
            "strip_prefix": pin["url"].split("/")[-1][:-len(".tar.xz")],
        }
    pin = PINS[role]
    return {
        "archive": ":" + pin["name"],
        "max_output": _MAX_OUTPUT[role],
        "sha256": pin["sha256"],
        "size_bytes": pin["size"],
        "strip_prefix": strip_prefix(role),
    }
