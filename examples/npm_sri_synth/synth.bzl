"""A synthetic package-lock.json of `n` packages, for the analysis-time measurement of the dynamic_output that reads it."""

def _impl(ctx):
    packages = {"": {"name": "synthetic", "version": "1.0.0"}}
    for i in range(ctx.attrs.n):
        s = str(i)

        # 85 base64 digits, then `A==`: a well-formed sha512 integrity that no bytes have.
        sri = "sha512-" + "0" * (85 - len(s)) + s + "A=="
        packages["node_modules/p" + s] = {
            "version": "1.0.0",
            "resolved": "data:application/octet-stream;base64,aGVsbG8K",
            "integrity": sri,
        }
    out = ctx.actions.write_json("package-lock.json", {"name": "synthetic", "version": "1.0.0", "lockfileVersion": 3, "packages": packages})
    return [DefaultInfo(default_output = out)]

synthetic_lock = rule(impl = _impl, attrs = {"n": attrs.int()})
