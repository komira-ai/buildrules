"""The pinned zig of the tool execution platform: which archive `:zig` and `:zig_next` unpack (rules/pins/BUCK)."""

load(":hosts.bzl", "HOST_PINS")
load(":pins.bzl", "PINS", "strip_prefix")

def tool_zig(role, local_mac):
    """The `archive` and `strip_prefix` of the `zig_dist` of the zig `role` (`zig`, `zig_next`). On a farm, and on any Linux machine, the linux x86_64 archive, as it always was.
    On a Mac that runs Buck2 itself (`local_mac`) the macOS archive of the same release (hosts.bzl); `zig_dist` unpacks it with the pinned `unpack` program."""
    if local_mac:
        pin = HOST_PINS["macos-aarch64"][role]
        return {"archive": ":macos-aarch64__" + pin["name"], "strip_prefix": pin["url"].split("/")[-1][:-len(".tar.xz")]}
    return {"archive": ":" + PINS[role]["name"], "busybox": ":busybox", "strip_prefix": strip_prefix(role)}
