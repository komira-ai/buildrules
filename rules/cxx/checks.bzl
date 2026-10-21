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
