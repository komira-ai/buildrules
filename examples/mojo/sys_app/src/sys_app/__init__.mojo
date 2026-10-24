"""sys_app: a consumer of a registry package that ships a static native library, with nothing written about it in the BUCK file.

probe_sys (an empty Mojo module over libprobe_sys.a) needs base_sys (an empty module over libbase_sys.a). Both archives come out of the
`.conda` files the lock pins, each hashed against the lock's value, and reach the linker in mopm's order: probe_sys's before base_sys's.
"""

from std.ffi import external_call


def answer() -> Int:
    """What libprobe_sys.a computes from libbase_sys.a's value: 1000 + 243."""
    return Int(external_call["probe_sys_answer", Int32]())


def clamped_answer(limit: Int) -> Int:
    """`answer()`, or `limit` when the answer is above it: a decision whose two arms a test takes by the limit it gives."""
    var value = answer()
    if value > limit:
        return limit
    return value
