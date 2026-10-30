"""`archive_files`: named files out of a sha256-pinned source archive.

A remote action unpacks the archive with the declared busybox and copies out
exactly the files listed in `files` (and `templates`); each becomes its own
output and a sub-target named by its path, so a `cxx_library` can name
`:<target>[snappy.cc]` as a source. A listed file missing from the archive
fails the action. A listed file that is a symbolic link of the archive, or lies
behind one, fails the action too: staging does not follow symbolic links from
an archive (links nothing lists are left alone).

With `one_tree`, the files are one directory output instead, and each
sub-target is a projection of it (see the attribute).

`templates` maps an output path to a file in the archive; every key of
`substitutions` is replaced, literally, by its value in each template (the
configure step of a CMake `configure_file`, without CMake).
"""

load("//rules/zig:zig.bzl", "busybox_sh")
load(":checks.bzl", "check_inside_archive", "check_listed_once", "check_tree_dirs")

_SCRIPT = """
BB="$1"; shift
case "$BB" in /*) ;; *) BB="$PWD/$BB" ;; esac
# Private scratch. A remote action has its working directory to itself; a
# local one runs in the checkout root next to every other local action, so
# it takes the per-action scratch directory buck2 names in BUCK_SCRATCH_PATH.
case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.buildrules_action" ;;
    /*) T="$BUCK_SCRATCH_PATH/buildrules" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/buildrules" ;;
esac
"$BB" mkdir -p "$T/bin" "$T/x"
"$BB" --install -s "$T/bin"
PATH="$T/bin"; export PATH
# The scratch goes with the action, a refusal included: a local action leaves it under buck-out, and a link of the archive in it would be walked by the file watcher.
# Directories are made writable first (find does not follow links; chmod -R would), so one the archive made unreadable does not keep the rest. A process that is
# killed (a timeout, SIGKILL) runs no trap and can still leave its scratch.
trap 'find "$T" -type d -exec chmod u+rwx {} \; 2>/dev/null; rm -rf "$T"' EXIT
ARCHIVE="$1"; PREFIX="$2"; SED="$3"; shift 3
case "$ARCHIVE" in
    *.tar.gz | *.tgz) tar -xzf "$ARCHIVE" -C "$T/x" ;;
    *.tar.xz) tar -xJf "$ARCHIVE" -C "$T/x" ;;
    *.tar) tar -xf "$ARCHIVE" -C "$T/x" ;;
    *.zip) unzip -q "$ARCHIVE" -d "$T/x" ;;
    *) echo "archive_files: unsupported archive type: $ARCHIVE" >&2; exit 2 ;;
esac
SRC="$T/x/$PREFIX"
# Staging never follows a symbolic link of the archive. A listed file that is a link, or lies behind one (a link to a directory, or in `strip_prefix`), would carry the copy to
# a path of the machine that unpacks it: it is refused, naming the link. Links nothing lists are never read.
# A hard link is not a link to follow: it is a second name of a file. When a listed file has more names than there are inside the unpacked tree, one is outside it (tar does
# not stop a member from being hard linked to a path of the machine, though the kernel or the file system often does), and the file is refused.
refuse_outside_names() {
    names=$(stat -c %h "$SRC/$1")
    [ "$names" -gt 1 ] || return 0
    # One dot per name found, not one line: a name that holds a newline would be counted twice and hide a name outside.
    inside=$(find "$T" -samefile "$SRC/$1" -exec printf . \; | wc -c)
    if [ "$names" -ne "$inside" ]; then
        echo "archive_files: $1 is not staged: it has $names names and $inside of them are in the unpacked tree of $ARCHIVE; staging does not take a hard link to a file outside it" >&2
        exit 2
    fi
}
refuse_links() {
    walk="$T/x"; rest="$PREFIX/$1"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest= ;; esac
        [ -n "$part" ] || continue
        walk="$walk/$part"
        if [ -L "$walk" ]; then
            echo "archive_files: $1 is not staged: ${walk#"$T/x/"} in $ARCHIVE is a symbolic link; staging does not follow symbolic links from an archive" >&2
            exit 2
        fi
    done
}
TREE=
while [ "$#" -gt 0 ]; do
    if [ "$1" = --tree ]; then TREE="$2/"; shift 2; continue; fi
    kind="$1"; rel="$2"; out="$TREE$3"; shift 3
    refuse_links "$rel"
    if [ ! -f "$SRC/$rel" ]; then
        echo "archive_files: $rel is not a file in $ARCHIVE (under '$PREFIX')" >&2
        exit 2
    fi
    refuse_outside_names "$rel"
    mkdir -p "$(dirname "$out")"
    case "$kind" in
        file) cp -P "$SRC/$rel" "$out" ;;
        template) sed -f "$SED" "$SRC/$rel" > "$out" ;;
    esac
done
"""

def _sed_escape(s, specials):
    for c in specials:
        s = s.replace(c, "\\" + c)
    return s

def _archive_files_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    archive = ctx.attrs.archive[DefaultInfo].default_outputs[0]
    lines = []
    for k, v in sorted(ctx.attrs.substitutions.items()):
        lines.append("s/{}/{}/g".format(
            _sed_escape(k, ["\\", "/", ".", "*", "[", "]", "^", "$"]),
            _sed_escape(v, ["\\", "/", "&"]),
        ))
    sed = ctx.actions.write("substitutions.sed", "\n".join(lines) + "\n")
    args = []
    sub_targets = {}
    outs = []
    tree = None
    if ctx.attrs.one_tree:
        tree = ctx.actions.declare_output("files", dir = True)
        args.extend(["--tree", tree.as_output()])
        outs.append(tree)
        for d in ctx.attrs.tree_dirs:
            sub_targets[d] = [DefaultInfo(default_output = tree.project(d))]
    check_tree_dirs(ctx.label, ctx.attrs.one_tree, ctx.attrs.tree_dirs)
    check_inside_archive(ctx.label, "strip_prefix", ctx.attrs.strip_prefix)
    for f in ctx.attrs.files:
        check_inside_archive(ctx.label, "file", f)
    for _, rel in sorted(ctx.attrs.templates.items()):
        check_inside_archive(ctx.label, "template source", rel)
    for kind, pairs in [("file", [(f, f) for f in ctx.attrs.files]), ("template", sorted(ctx.attrs.templates.items()))]:
        for name, rel in pairs:
            check_listed_once(ctx.label, name, sub_targets)
            if tree:
                args.extend([kind, rel, name])
                sub_targets[name] = [DefaultInfo(default_output = tree.project(name))]
            else:
                out = ctx.actions.declare_output("files/" + name)
                args.extend([kind, rel, out.as_output()])
                sub_targets[name] = [DefaultInfo(default_output = out)]
                outs.append(out)
    ctx.actions.run(
        cmd_args(busybox_sh(bb, _SCRIPT, archive, ctx.attrs.strip_prefix, sed, args), hidden = ctx.attrs.busybox[DefaultInfo].other_outputs),
        category = "archive_files",
    )
    return [DefaultInfo(default_outputs = outs, sub_targets = sub_targets)]

archive_files_rule = rule(
    impl = _archive_files_impl,
    attrs = {
        # A pinned_file holding the archive; its name must end in the format.
        "archive": attrs.dep(),
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "files": attrs.list(attrs.string(), default = []),
        # One output, a directory holding every file at its path in the
        # archive (each file's sub-target is a projection of it), so that a
        # source finds what it includes by relative path ("../internal.h").
        # Separate outputs may each get a content-based path of their own.
        "one_tree": attrs.bool(default = False),
        "strip_prefix": attrs.string(default = ""),
        "substitutions": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "templates": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # With one_tree: directories of the tree that are sub-targets of their
        # own, for an -I flag ($(location :<target>[include])).
        "tree_dirs": attrs.list(attrs.string(), default = []),
    },
)


archive_files = archive_files_rule
