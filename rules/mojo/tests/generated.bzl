"""Path dependencies whose library is not at `<dir>/src/<name>` (rules/mojo/defs.bzl, `member_label` and `manifest_directories`): a package whose mopm.toml says
`[targets] lib = { path = "generated/<name>" }`, as one does whose sources are committed generator output. Its directory is the longest directory with a
mopm.toml that the table records and that holds the library: the checks of rules/mojo/tests/BUCK.

A check takes the way to refuse as an argument (rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:defs.bzl", "manifest_directories", "member_label")

_ID = "json@1.0.0#mojo1.0.0/lib"

def generated_sibling_is_named_by_its_manifest_directory(refuse = fail):
    """A sibling whose library is `generated/<name>` is `//<its directory>:lib`, from either base of the graph's paths."""
    got = member_label("src/codec", _ID, "json", "src/json/generated/json", "", refuse, ["src/codec", "src/json"])
    if got != "//src/json:lib":
        refuse("a sibling with a generated library is not named by its manifest's directory: {}".format(got))
    got = member_label("src/codec", _ID, "json", "../json/generated/json", "src/codec", refuse, ["src/codec", "src/json"])
    if got != "//src/json:lib":
        refuse("a sibling with a generated library, written with .. from the package, is not named by its manifest's directory: {}".format(got))

def generated_member_below_the_package_is_named_by_its_manifest_directory(refuse = fail):
    """A member below the package, with the paths from the package."""
    got = member_label("examples/ws", _ID, "json", "util/generated/json", "examples/ws", refuse, ["examples/ws", "examples/ws/util"])
    if got != "//examples/ws/util:lib":
        refuse("a member below the package with a generated library is not named by its manifest's directory: {}".format(got))

def longest_manifest_directory_wins(refuse = fail):
    """A member inside another member's directory is named by its own manifest, not by the outer one."""
    got = member_label("src/codec", _ID, "json", "src/json/inner/generated/json", "", refuse, ["src/codec", "src/json", "src/json/inner"])
    if got != "//src/json/inner:lib":
        refuse("the outer manifest's directory was taken for a member with a manifest of its own: {}".format(got))

def src_name_is_read_before_the_manifests(refuse = fail):
    """A library at `<dir>/src/<name>` is named by that directory as it always was, whatever manifests the table records."""
    got = member_label("src/codec", _ID, "json", "src/json/src/json", "", refuse, ["src/codec", "src/json/src"])
    if got != "//src/json:lib":
        refuse("a library at src/<name> is not named by the directory above src: {}".format(got))

def manifest_directories_are_those_of_the_recorded_manifests(refuse = fail):
    """The directories of the `mopm.toml` keys of a table (relative to the package, `..` allowed), as repository paths; the other recorded files name none."""
    table = {"MANIFEST_SHA256": {
        "../../mopm-toolchain.toml": "a",
        "../json/mopm.toml": "b",
        "mopm.lock": "c",
        "mopm.toml": "d",
        "util/mopm.lock": "e",
        "util/mopm.toml": "f",
    }}
    got = manifest_directories(table, "src/codec")
    want = ["src/codec", "src/codec/util", "src/json"]
    if got != want:
        refuse("the manifest directories are {} and not {}".format(got, want))
    got = manifest_directories({"MANIFEST_SHA256": {"mopm.toml": "a", "util/mopm.toml": "b"}}, "")
    if got != ["", "util"]:
        refuse("a package at the repository root has no directory but the empty one: {}".format(got))
