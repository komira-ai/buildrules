"""A rule with no action whose attributes record what buildrules' platform helpers answered while this cell's BUCK file loaded (ci/root_keys.bzl reads them)."""

def _impl(ctx):
    return [DefaultInfo()]

probe = rule(
    impl = _impl,
    attrs = {
        "linux_arm64_enabled": attrs.string(),
        "linux_arm64_gate": attrs.string(),
        "linux_aarch64_ready": attrs.string(),
        "macos_aarch64_missing": attrs.string(),
        "macos_aarch64_ready": attrs.string(),
    },
)
