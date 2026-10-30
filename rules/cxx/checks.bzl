"""What the C/C++ rules refuse at analysis (archive.bzl), as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule: the build stops at the first refusal, with its message. A test passes a
recorder instead (rules/rust/refusal.bzl) and reads what was refused (rules/cxx/tests).
"""

def check_tree_dirs(who, one_tree, tree_dirs, refuse = fail):
    """`tree_dirs` are sub-targets of the one tree, so they need `one_tree = True`."""
    if tree_dirs and not one_tree:
        refuse("{}: tree_dirs needs one_tree = True".format(who))

def check_listed_once(who, name, taken, refuse = fail):
    """A file or template is listed once: `name` is a sub-target, and `taken` holds the sub-targets so far."""
    if name in taken:
        refuse("{}: {} is listed twice".format(who, name))

def check_inside_archive(who, what, path, refuse = fail):
    """A path written in a BUCK file (a listed file, a template's source, strip_prefix) names a place inside the archive: absolute, or with a `..` component, it does not."""
    if path.startswith("/") or ".." in path.split("/"):
        refuse("{}: {} {} is not a path inside the archive: a path may not be absolute or hold a .. component".format(who, what, path))
