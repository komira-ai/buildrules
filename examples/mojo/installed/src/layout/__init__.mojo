"""layout: where a running program finds its own files (BUCK, `test_layout = "installed"`).

A program installed as `<root>/bin/<exe>` with its data in `<root>/share` finds them from its own path: `executable_path()` is the path the kernel gives the
running binary (a symbolic link in it is resolved), `install_root()` is the directory above its `bin/`, `share_dir()` is the `share/` beside that `bin/`, and
`current_dir()` is the working directory. The tests of this package run in exactly that layout and check each of them against it.
"""

from std.ffi import external_call
from std.os import listdir

comptime _PATH_CAP: Int = 4096


def _zeroed(n: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    for _ in range(n):
        buf.append(UInt8(0))
    return buf^


def _decode(buf: List[UInt8]) -> String:
    """The bytes of `buf` before its first NUL."""
    var out = String("")
    var i = 0
    while i < len(buf) and buf[i] != UInt8(0):
        out += chr(Int(buf[i]))
        i += 1
    return out^


def executable_path() raises -> String:
    """The absolute path of the running executable, as /proc/self/exe names it."""
    var buf = _zeroed(_PATH_CAP)
    var link = String("/proc/self/exe")
    # SAFETY: `link` and `buf` are locals that outlive the call; readlink writes at most `_PATH_CAP - 1` bytes into the zero-filled `buf`, so the byte after
    # them is a NUL.
    var n = external_call["readlink", Int](
        link.as_c_string_slice().unsafe_ptr(),
        buf.unsafe_ptr(),
        UInt(_PATH_CAP - 1),
    )
    if n <= 0:
        raise Error("executable_path: readlink(/proc/self/exe) failed")
    return _decode(buf)


def current_dir() raises -> String:
    """The absolute path of the working directory."""
    var buf = _zeroed(_PATH_CAP)
    # SAFETY: `buf` is a local that outlives the call; getcwd writes at most `_PATH_CAP` bytes into it, NUL included.
    var r = external_call["getcwd", Int](buf.unsafe_ptr(), UInt(_PATH_CAP))
    if r == 0:
        raise Error("current_dir: getcwd failed")
    return _decode(buf)


def parent_of(path: String) -> String:
    """The directory part of `path`: everything before its last `/` (`/` for a path directly under the root)."""
    var i = path.rfind("/")
    if i <= 0:
        return String("/")
    return String(path[byte=:i])


def install_root() raises -> String:
    """`<root>`: the parent of the directory that holds the executable."""
    return parent_of(parent_of(executable_path()))


def share_dir() raises -> String:
    """`<root>/share`, where the data a test or a bundle declares is."""
    return install_root() + "/share"


def is_absolute(path: String) -> Bool:
    return path.startswith("/")


def entry_count(dir: String) raises -> Int:
    """How many entries the directory `dir` holds."""
    return len(listdir(dir))
