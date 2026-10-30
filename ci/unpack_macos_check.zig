//! The `unpack_macos` job of .github/workflows/ci.yml does what it is for: GitHub's macos-15 runner builds `unpack` with the pinned zig 0.15.2 for macOS, runs its unit
//! tests, and unpacks the REAL darwin zig 0.12.0 tarball, comparing the tree with the system tar's and running the zig it made. The job's urls and digests are the ones in
//! rules/pins/hosts.bzl (a job that fetched another file would prove nothing about the pinned one). A pure function of the two texts, tested against faulty text.
const std = @import("std");
const t = std.testing;

pub const Findings = std.ArrayList([]u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(a, try std.fmt.allocPrint(a, fmt, args));
}

/// The lines of the job `name`: from its key to the next job (two spaces and a name).
fn jobBlock(workflow: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const key = std.fmt.bufPrint(buf, "\n  {s}:\n", .{name}) catch return null;
    const at = std.mem.indexOf(u8, workflow, key) orelse return null;
    const body = workflow[at + 1 ..];
    var pos: usize = key.len - 1;
    while (std.mem.indexOfPos(u8, body, pos, "\n  ")) |i| {
        const c = if (i + 3 < body.len) body[i + 3] else ' ';
        if (c != ' ' and c != '#' and c != '\n') return body[0..i];
        pos = i + 1;
    }
    return body;
}

/// The value of `"key": "..."` (or `"key": N,`) in the block of `host`'s `role` row of hosts.bzl.
fn field(hosts: []const u8, host: []const u8, role: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const hk = std.fmt.bufPrint(&buf, "\"{s}\": {{", .{host}) catch return null;
    const h = std.mem.indexOf(u8, hosts, hk) orelse return null;
    var rbuf: [64]u8 = undefined;
    const rk = std.fmt.bufPrint(&rbuf, "\"{s}\": {{", .{role}) catch return null;
    const r = std.mem.indexOfPos(u8, hosts, h, rk) orelse return null;
    const end = std.mem.indexOfPos(u8, hosts, r, "},") orelse hosts.len;
    const row = hosts[r..end];
    var kbuf: [64]u8 = undefined;
    const kk = std.fmt.bufPrint(&kbuf, "\"{s}\": ", .{key}) catch return null;
    const k = std.mem.indexOf(u8, row, kk) orelse return null;
    var v = row[k + kk.len ..];
    v = v[0 .. std.mem.indexOfAny(u8, v, "\n") orelse v.len];
    // a quoted value is the text between the last two quotes (a url is written `_ZIG + "0.12.0/zig-..."`); a number is what is left of the comma
    if (std.mem.lastIndexOfScalar(u8, v, '"')) |close| {
        const open = std.mem.lastIndexOfScalar(u8, v[0..close], '"') orelse return null;
        return v[open + 1 .. close];
    }
    return std.mem.trim(u8, v, " ,");
}

fn mentions(job: []const u8, text: []const u8) bool {
    return std.mem.indexOf(u8, job, text) != null;
}

/// The value of `"key": ...` in the `host` row of rules/pins/bootstrap.bzl (one level: host, then key).
fn pinField(bootstrap: []const u8, host: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const hk = std.fmt.bufPrint(&buf, "\"{s}\": {{", .{host}) catch return null;
    const h = std.mem.indexOf(u8, bootstrap, hk) orelse return null;
    const end = std.mem.indexOfPos(u8, bootstrap, h, "},") orelse bootstrap.len;
    const row = bootstrap[h..end];
    var kbuf: [64]u8 = undefined;
    const kk = std.fmt.bufPrint(&kbuf, "\"{s}\": ", .{key}) catch return null;
    const k = std.mem.indexOf(u8, row, kk) orelse return null;
    var v = row[k + kk.len ..];
    v = v[0 .. std.mem.indexOfAny(u8, v, "\n") orelse v.len];
    return std.mem.trim(u8, v, " ,\"");
}

/// The lowest macOS the macOS programs of buildrules run on: what the pinned zig 0.15.2 targets for `aarch64-macos` with no version. The job builds for it and fails when a Mach-O is above it.
pub const macos_min = "13.0";

pub fn check(a: std.mem.Allocator, workflow: []const u8, hosts: []const u8, bootstrap: []const u8) !Findings {
    var f = Findings.empty;
    var buf: [64]u8 = undefined;
    const job = jobBlock(workflow, "unpack_macos", &buf) orelse {
        try add(a, &f, "the `unpack_macos` job is missing (macos-15: build unpack, run its tests, unpack the real darwin zig tarball)", .{});
        return f;
    };
    if (!mentions(job, "\n    runs-on: macos-15\n")) try add(a, &f, "the unpack_macos job does not run on `runs-on: macos-15` (an aarch64 macOS machine)", .{});
    if (!mentions(job, "test \"$(uname -s)-$(uname -m)\" = Darwin-arm64")) try add(a, &f, "the unpack_macos job does not assert the machine is Darwin-arm64", .{});
    for ([_][]const u8{ "zig_next", "zig" }) |role| {
        const url = field(hosts, "macos-aarch64", role, "url") orelse "";
        const sha = field(hosts, "macos-aarch64", role, "sha256") orelse "";
        if (url.len == 0 or sha.len != 64) {
            try add(a, &f, "rules/pins/hosts.bzl has no url and sha256 for the macos-aarch64 `{s}` row", .{role});
            continue;
        }
        if (!mentions(job, url)) try add(a, &f, "the unpack_macos job does not fetch the macos-aarch64 `{s}` url of hosts.bzl ({s})", .{ role, url });
        if (!mentions(job, sha)) try add(a, &f, "the unpack_macos job does not use the macos-aarch64 `{s}` sha256 of hosts.bzl ({s})", .{ role, sha });
    }
    if (field(hosts, "macos-aarch64", "zig_next", "sha256")) |sha| {
        const line = try std.fmt.allocPrint(a, "echo \"{s}  zig-next.tar.xz\" | shasum -a 256 -c -", .{sha});
        defer a.free(line);
        if (!mentions(job, line)) try add(a, &f, "the unpack_macos job does not check the sha256 of the zig it builds with (`{s}`)", .{line});
    }
    const sha12 = field(hosts, "macos-aarch64", "zig", "sha256") orelse "";
    const size12 = field(hosts, "macos-aarch64", "zig", "size") orelse "";
    const unpack_cmd = try std.fmt.allocPrint(a, "./cross/unpack-macos-aarch64 --strip-components 1 --sha256 {s} --size {s} zig-darwin.tar.xz zig-from-unpack", .{ sha12, size12 });
    defer a.free(unpack_cmd);
    if (!mentions(job, unpack_cmd)) try add(a, &f, "the unpack_macos job does not unpack the darwin zig with its sha256 and size checked (`{s}`)", .{unpack_cmd});
    if (!mentions(job, "./zig-next/zig build-exe -OReleaseSafe -fstrip tools/bootstrap/src/unpack.zig -femit-bin=unpack-native")) try add(a, &f, "the unpack_macos job does not build tools/bootstrap/src/unpack.zig with the pinned zig", .{});
    // The macOS minimum: the program is built for the pinned target, and it and the pinned cross build are held to the same limit by ci/macho_minos.zig.
    if (!mentions(job, "-target aarch64-macos." ++ macos_min ++ " tools/bootstrap/src/unpack.zig -femit-bin=unpack-pinned")) try add(a, &f, "the unpack_macos job does not build unpack for `-target aarch64-macos." ++ macos_min ++ "`, the pinned macOS minimum", .{});
    if (!mentions(job, "./zig-next/zig run ci/macho_minos.zig -- --max " ++ macos_min ++ " cross/unpack-macos-aarch64 unpack-pinned\n")) try add(a, &f, "the unpack_macos job does not check the minos of the pinned program and of the pinned build against " ++ macos_min ++ " (ci/macho_minos.zig)", .{});
    if (!mentions(job, "./zig-next/zig test \"tools/bootstrap/src/${name}_test.zig\"")) try add(a, &f, "the unpack_macos job does not run the unit tests natively", .{});
    if (!mentions(job, "diff -r zig-from-tar zig-from-unpack")) try add(a, &f, "the unpack_macos job does not compare the tree with the system tar's (`diff -r zig-from-tar zig-from-unpack`)", .{});
    if (!mentions(job, "test \"$(./zig-from-unpack/zig version)\" = 0.12.0")) try add(a, &f, "the unpack_macos job does not run the unpacked zig and check its version is 0.12.0", .{});
    if (!mentions(job, "if ./cross/unpack-macos-aarch64 --check zig-cut.tar.xz; then")) try add(a, &f, "the unpack_macos job does not require a cut-off tarball to be refused", .{});
    if (!mentions(job, "\n    needs: unpack_cross\n")) try add(a, &f, "the unpack_macos job does not wait for `unpack_cross`, which builds the program it runs", .{});
    if (!mentions(job, "actions/download-artifact@") or !mentions(job, "name: unpack-macos-aarch64\n")) try add(a, &f, "the unpack_macos job does not download the artifact `unpack-macos-aarch64`", .{});
    const pin_sha = pinField(bootstrap, "macos-aarch64", "sha256") orelse "";
    const pin_size = pinField(bootstrap, "macos-aarch64", "size") orelse "";
    if (pin_sha.len != 64 or pin_size.len == 0) {
        try add(a, &f, "rules/pins/bootstrap.bzl has no sha256 and size for the macos-aarch64 row", .{});
    } else {
        const sha_line = try std.fmt.allocPrint(a, "echo \"{s}  cross/unpack-macos-aarch64\" | shasum -a 256 -c -", .{pin_sha});
        defer a.free(sha_line);
        if (!mentions(job, sha_line)) try add(a, &f, "the unpack_macos job does not check the program against the sha256 pinned in bootstrap.bzl (`{s}`)", .{sha_line});
        const size_line = try std.fmt.allocPrint(a, "test \"$(stat -f %z cross/unpack-macos-aarch64)\" = {s}", .{pin_size});
        defer a.free(size_line);
        if (!mentions(job, size_line)) try add(a, &f, "the unpack_macos job does not check the program against the size pinned in bootstrap.bzl (`{s}`)", .{size_line});
    }
    if (!mentions(job, "chmod +x cross/unpack-macos-aarch64")) try add(a, &f, "the unpack_macos job does not make the downloaded program executable", .{});
    if (!mentions(job, "find . -print0 | sort -z | xargs -0 stat -f '%N %Lp %Y') > listing-tar.txt") or !mentions(job, "find . -print0 | sort -z | xargs -0 stat -f '%N %Lp %Y') > listing-unpack.txt") or !mentions(job, "diff listing-tar.txt listing-unpack.txt")) try add(a, &f, "the unpack_macos job does not compare the modes and symbolic links of the two trees", .{});
    if (mentions(job, "continue-on-error")) try add(a, &f, "the unpack_macos job has `continue-on-error`: a red step would pass", .{});
    var cbuf: [64]u8 = undefined;
    const cross = jobBlock(workflow, "unpack_cross", &cbuf) orelse {
        try add(a, &f, "the `unpack_cross` job is missing (it builds the macOS program the macOS job runs)", .{});
        return f;
    };
    if (!mentions(cross, "\n    runs-on: ubuntu-latest\n")) try add(a, &f, "the unpack_cross job does not run on ubuntu-latest", .{});
    if (!mentions(cross, "./buck2 build --console simple -c buildrules_re.mode=local --out unpack-macos-aarch64 //tools/bootstrap:unpack_macos_aarch64")) try add(a, &f, "the unpack_cross job does not build //tools/bootstrap:unpack_macos_aarch64 as `unpack-macos-aarch64`", .{});
    if (!mentions(cross, "actions/upload-artifact@") or !mentions(cross, "name: unpack-macos-aarch64\n") or !mentions(cross, "path: unpack-macos-aarch64\n")) try add(a, &f, "the unpack_cross job does not upload the artifact `unpack-macos-aarch64`", .{});
    if (mentions(cross, "continue-on-error")) try add(a, &f, "the unpack_cross job has `continue-on-error`: a red step would pass", .{});
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const ta = t.allocator;

fn real() !struct { wf: []u8, hosts: []u8, bootstrap: []u8 } {
    const work = try std.process.getEnvVarOwned(ta, "BUILDRULES_TEST_WORK");
    defer ta.free(work);
    try std.posix.chdir(work);
    return .{
        .wf = try std.fs.cwd().readFileAlloc(ta, ".github/workflows/ci.yml", 1 << 20),
        .hosts = try std.fs.cwd().readFileAlloc(ta, "rules/pins/hosts.bzl", 1 << 20),
        .bootstrap = try std.fs.cwd().readFileAlloc(ta, "rules/pins/bootstrap.bzl", 1 << 20),
    };
}

fn free(f: *Findings) void {
    for (f.items) |x| ta.free(x);
    f.deinit(ta);
}

fn mutate(text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, from) orelse return error.DefectAnchorMissing;
    return std.mem.concat(ta, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn expectFinding(wf: []const u8, hosts: []const u8, bootstrap: []const u8, want: []const u8) !void {
    var f = try check(ta, wf, hosts, bootstrap);
    defer free(&f);
    for (f.items) |x| {
        if (std.mem.indexOf(u8, x, want) != null) return;
    }
    std.debug.print("no finding with `{s}`; got {d}:\n", .{ want, f.items.len });
    for (f.items) |x| std.debug.print("  {s}\n", .{x});
    return error.TestExpectedFinding;
}

test "the real workflow and table agree" {
    const r = try real();
    defer ta.free(r.wf);
    defer ta.free(r.hosts);
    defer ta.free(r.bootstrap);
    var f = try check(ta, r.wf, r.hosts, r.bootstrap);
    defer free(&f);
    for (f.items) |x| std.debug.print("{s}\n", .{x});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "every part of the job is required" {
    const r = try real();
    defer ta.free(r.wf);
    defer ta.free(r.hosts);
    defer ta.free(r.bootstrap);
    const cases = [_][2][]const u8{
        .{ "    runs-on: macos-15\n    needs: unpack_cross", "    runs-on: ubuntu-latest\n    needs: unpack_cross" },
        .{ "    needs: unpack_cross\n", "    needs: other\n" },
        .{ "name: unpack-macos-aarch64\n          path: cross", "name: unpack-macos\n          path: cross" },
        .{ "chmod +x cross/unpack-macos-aarch64", "true" },
        .{ "test \"$(stat -f %z cross/unpack-macos-aarch64)\" = ", "test \"$(stat -f %z cross/unpack-macos-aarch64)\" != " },
        .{ "diff listing-tar.txt listing-unpack.txt", "true" },
        .{ "%N %Lp %Y') > listing-unpack.txt", "%N %Y') > listing-unpack.txt" },
        .{ "--out unpack-macos-aarch64 //tools/bootstrap:unpack_macos_aarch64", "--out unpack-macos-aarch64 //tools/bootstrap:unpack_linux_aarch64" },
        .{ "          path: unpack-macos-aarch64\n", "          path: other\n" },
        .{ "  unpack_cross:\n    runs-on: ubuntu-latest", "  unpack_cross:\n    runs-on: macos-15" },
        .{ "= Darwin-arm64", "= Linux-x86_64" },
        .{ "zig-aarch64-macos-0.15.2.tar.xz", "zig-aarch64-macos-0.15.1.tar.xz" },
        .{ "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b  zig-next", "4cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b  zig-next" },
        .{ "shasum -a 256 -c -", "true" },
        .{ "0.12.0/zig-macos-aarch64-0.12.0.tar.xz", "0.12.0/zig-linux-aarch64-0.12.0.tar.xz" },
        .{ "--sha256 294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f --size 43447724", "--size 43447724" },
        .{ "--size 43447724 zig-darwin", "--size 43447725 zig-darwin" },
        .{ "-femit-bin=unpack-native", "-femit-bin=other" },
        .{ "-target aarch64-macos.13.0 tools", "-target aarch64-macos.15.0 tools" },
        .{ "-target aarch64-macos.13.0 tools", "-target aarch64-macos tools" },
        .{ "macho_minos.zig -- --max 13.0 cross", "macho_minos.zig -- --max 15.0 cross" },
        .{ "cross/unpack-macos-aarch64 unpack-pinned\n", "unpack-pinned\n" },
        .{ "ci/macho_minos.zig -- --max 13.0 cross/unpack-macos-aarch64 unpack-pinned", "true" },
        .{ "tools/bootstrap/src/${name}_test.zig", "tools/bootstrap/src/paths_test.zig" },
        .{ "diff -r zig-from-tar zig-from-unpack", "true" },
        .{ "= 0.12.0", "= 0.12.1" },
        .{ "if ./cross/unpack-macos-aarch64 --check zig-cut.tar.xz; then", "if true; then" },
    };
    for (cases) |c| {
        const m = try mutate(r.wf, c[0], c[1]);
        defer ta.free(m);
        var f = try check(ta, m, r.hosts, r.bootstrap);
        defer free(&f);
        if (f.items.len == 0) {
            std.debug.print("changing `{s}` to `{s}` was not found\n", .{ c[0], c[1] });
            return error.TestExpectedFinding;
        }
    }
}

test "a missing job, a continue-on-error and a table without the rows are found" {
    const r = try real();
    defer ta.free(r.wf);
    defer ta.free(r.hosts);
    defer ta.free(r.bootstrap);
    const gone = try mutate(r.wf, "\n  unpack_macos:\n", "\n  unpack_other:\n");
    defer ta.free(gone);
    try expectFinding(gone, r.hosts, r.bootstrap, "`unpack_macos` job is missing");
    const coe = try mutate(r.wf, "    runs-on: macos-15\n", "    runs-on: macos-15\n    continue-on-error: true\n");
    defer ta.free(coe);
    try expectFinding(coe, r.hosts, r.bootstrap, "continue-on-error");
    const nohost = try mutate(r.hosts, "\"macos-aarch64\": {", "\"macos-arm\": {");
    defer ta.free(nohost);
    try expectFinding(r.wf, nohost, r.bootstrap, "has no url and sha256 for the macos-aarch64");
    // the job and the table drifting apart is found from the table's side too
    const drift = try mutate(r.hosts, "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b", "5cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b");
    defer ta.free(drift);
    try expectFinding(r.wf, drift, r.bootstrap, "does not use the macos-aarch64 `zig_next` sha256");
}

test "the job block ends at the next job" {
    const wf = "jobs:\n  a:\n    x: 1\n  # a comment\n    y: 2\n  unpack_macos:\n    runs-on: macos-15\n  b:\n    z: 3\n";
    var buf: [64]u8 = undefined;
    const job = jobBlock(wf, "unpack_macos", &buf).?;
    try t.expect(std.mem.indexOf(u8, job, "macos-15") != null);
    try t.expect(std.mem.indexOf(u8, job, "z: 3") == null);
    // the last job runs to the end of the file
    const last = jobBlock("jobs:\n  unpack_macos:\n    k: v\n", "unpack_macos", &buf).?;
    try t.expect(std.mem.indexOf(u8, last, "k: v") != null);
    try t.expect(jobBlock(wf, "missing", &buf) == null);
}

test "the program the job runs is the one the pin table names: a changed row, or no row, is found" {
    const r = try real();
    defer ta.free(r.wf);
    defer ta.free(r.hosts);
    defer ta.free(r.bootstrap);
    const sha = pinField(r.bootstrap, "macos-aarch64", "sha256").?;
    try t.expectEqual(@as(usize, 64), sha.len);
    const changed = try mutate(r.bootstrap, sha, "0" ** 64);
    defer ta.free(changed);
    try expectFinding(r.wf, r.hosts, changed, "does not check the program against the sha256 pinned in bootstrap.bzl");
    const size = pinField(r.bootstrap, "macos-aarch64", "size").?;
    const resized = try mutate(r.bootstrap, size, "7");
    defer ta.free(resized);
    try expectFinding(r.wf, r.hosts, resized, "does not check the program against the size pinned in bootstrap.bzl");
    const none = try mutate(r.bootstrap, "\"macos-aarch64\": {", "\"macos-arm\": {");
    defer ta.free(none);
    try expectFinding(r.wf, r.hosts, none, "has no sha256 and size for the macos-aarch64 row");
    const nocross = try mutate(r.wf, "\n  unpack_cross:\n", "\n  unpack_elsewhere:\n");
    defer ta.free(nocross);
    try expectFinding(nocross, r.hosts, r.bootstrap, "`unpack_cross` job is missing");
    const coe = try mutate(r.wf, "  unpack_cross:\n    runs-on: ubuntu-latest\n", "  unpack_cross:\n    runs-on: ubuntu-latest\n    continue-on-error: true\n");
    defer ta.free(coe);
    try expectFinding(coe, r.hosts, r.bootstrap, "unpack_cross job has `continue-on-error`");
}
