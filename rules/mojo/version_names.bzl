"""The Mojo versions a target platform can ask for (rules/mojo/versions.bzl), in a file that loads nothing: platforms/BUCK and rules/matrix.bzl read it."""

# One constraint value and one config setting each (platforms/BUCK: `mojo_<v>`, `mojo_is_<v>`) and one transition each (rules/matrix.bzl, `mojo_at`). They are
# names, not pins: the toolchain of a version is mopm's (toolchains/mojo_pins.bzl). A version that is not here can be a package's default (the build without
# the constraint), never one of its other versions.
MOJO_VERSIONS = ["1.0.0", "1.1.0", "1.2.0"]

def mojo_vname(version):
    """`1.2.0` -> `1_2_0`: the part of a target name that tells the Mojo version."""
    return version.replace(".", "_")

def mojo_setting(version):
    """The config setting a target platform that asks for Mojo `version` matches."""
    return "buildrules//platforms:mojo_is_" + mojo_vname(version)
