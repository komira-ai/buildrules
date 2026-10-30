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

_NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"

def is_cxx_namespace(s):
    """Whether `s` is a C++ namespace a renamed library may keep: an identifier (letters, digits and `_`, not starting with a digit), and not `std`."""
    return type(s) == "string" and len(s) > 0 and s != "std" and s[0] not in "0123456789" and all([c in _NAME_CHARS for c in s.elems()])

def check_cxx_namespaces(who, spaces, refuse = fail):
    """Each of `spaces` (`prefix_cxx_namespaces`) is a namespace: an identifier that does not start with a digit, and not `std`."""
    for ns in spaces:
        if not is_cxx_namespace(ns):
            refuse("{}: prefix_cxx_namespaces holds {}; a namespace is an identifier: letters, digits and _, not starting with a digit, and not empty or std".format(who, repr(ns)))
            return
