//! The cases of files.zig: `check same`, `check copy` and `check digest`. The digests are the published ones (FIPS 180 test vectors for `abc` and
//! the empty message), so no case depends on the code that computes them.

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");

const SHA256_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
const SHA512_ABC = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";
const SHA256_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const SHA512_EMPTY = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
const SRI256_ABC = "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=";
const SRI512_ABC = "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==";

// ---- same -------------------------------------------------------------------------------------------------------

fn bytes(c: *kit.Case, n: usize) ![]u8 {
    const b = try c.alloc().alloc(u8, n);
    for (b, 0..) |*x, i| x.* = @intCast((i * 7 + i / 251) % 256);
    return b;
}

test "same: equal files write the stamp and exit 0, whatever the length: empty, one byte, a chunk exactly, several chunks" {
    var c = try kit.Case.init();
    defer c.deinit();
    for ([_]usize{ 0, 1, 8191, 8192, 8193, 16384, 20000 }) |n| {
        const b = try bytes(&c, n);
        try c.put("a", b);
        try c.put("b", b);
        c.tmp.dir.deleteFile("o") catch {};
        try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "b" }), 0, "", "");
        try t.expectEqualStrings("same\n", try c.read("o"));
    }
}

test "same: the first difference is named by its byte, at the start, at the end of a chunk, at the start of the next, at the end" {
    var c = try kit.Case.init();
    defer c.deinit();
    const b = try bytes(&c, 20000);
    try c.put("a", b);
    const cases = [_][2][]const u8{
        .{ "0", "1" },
        .{ "8191", "8192" },
        .{ "8192", "8193" },
        .{ "16383", "16384" },
        .{ "19999", "20000" },
    };
    for (cases) |case| {
        const at = try std.fmt.parseInt(usize, case[0], 10);
        const changed = try c.alloc().dupe(u8, b);
        changed[at] ^= 0x40;
        try c.put("b", changed);
        const want = try std.fmt.allocPrint(c.alloc(), "check same: a and b differ at byte {s}\n", .{case[1]});
        try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "b" }), 1, "", want);
        try t.expect(!c.exists("o"));
    }
}

test "same: a file that ends where the other goes on differs, either way round, at a chunk boundary or not" {
    var c = try kit.Case.init();
    defer c.deinit();
    const b = try bytes(&c, 20000);
    for ([_]usize{ 100, 8192, 8000 }) |n| {
        try c.put("a", b[0..n]);
        try c.put("b", b[0 .. n + 8]);
        const first = try std.fmt.allocPrint(c.alloc(), "check same: a and b differ: a ends after {d} bytes and the other goes on\n", .{n});
        try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "b" }), 1, "", first);
        const second = try std.fmt.allocPrint(c.alloc(), "check same: b and a differ: a ends after {d} bytes and the other goes on\n", .{n});
        try kit.expectResult(try c.run(&.{ "same", "--out", "o", "b", "a" }), 1, "", second);
    }
    try c.put("empty", "");
    try c.put("one", "x");
    try kit.expectFailure(try c.run(&.{ "same", "--out", "o", "empty", "one" }), 1, "empty ends after 0 bytes");
    try t.expect(!c.exists("o"));
}

test "same: a difference leaves an earlier stamp as it was; --stamp is what is written" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try c.put("b", "2");
    try c.put("o", "earlier");
    try kit.expectFailure(try c.run(&.{ "same", "--out", "o", "a", "b" }), 1, "differ at byte 1");
    try t.expectEqualStrings("earlier", try c.read("o"));
    try c.put("b", "1");
    try kit.expectResult(try c.run(&.{ "same", "--stamp", "identical", "--out", "o", "a", "b" }), 0, "", "");
    try t.expectEqualStrings("identical", try c.read("o"));
}

test "same: a file that cannot be read is status 2 and is named" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "nope", "a" }), 2, "", "check same: cannot read nope: FileNotFound\n");
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "nope" }), 2, "", "check same: cannot read nope: FileNotFound\n");
    try c.tmp.dir.makePath("d");
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "d", "a" }), 2, "", "check same: cannot compare d and a: IsDir\n");
    try t.expect(!c.exists("o"));
}

test "same: the command line is --out, --stamp, then two files; anything else is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    const usage = "check same: usage: check same --out FILE [--stamp TEXT] A B\n";
    try kit.expectResult(try c.run(&.{ "same", "a", "a" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "a", "a" }), 2, "", usage);
    // options come first
    try kit.expectResult(try c.run(&.{ "same", "a", "a", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "same", "--out" }), 2, "", "check same: --out needs a value\n");
    try kit.expectResult(try c.run(&.{ "same", "--bogus", "x", "a", "a" }), 2, "", "check same: unknown option --bogus\n");
    try t.expect(!c.exists("o"));
}

test "same: a stamp that cannot be written is status 1 with the reason" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try kit.expectFailure(try c.run(&.{ "same", "--out", "no-dir/o", "a", "a" }), 1, "check same: cannot write no-dir/o: temporary file: FileNotFound");
}

// ---- copy -------------------------------------------------------------------------------------------------------

test "copy: the bytes arrive, whole, for any length; an existing destination is replaced" {
    var c = try kit.Case.init();
    defer c.deinit();
    for ([_]usize{ 0, 1, 70000 }) |n| {
        const b = try bytes(&c, n);
        try c.put("src", b);
        try c.put("dst", "an older file, longer than the new one is when n is zero or one........................");
        try kit.expectResult(try c.run(&.{ "copy", "src", "dst" }), 0, "", "");
        try t.expectEqualSlices(u8, b, try c.read("dst"));
    }
    try c.put("sub/src", "in a subdirectory");
    try kit.expectResult(try c.run(&.{ "copy", "sub/src", "sub/dst" }), 0, "", "");
    try t.expectEqualStrings("in a subdirectory", try c.read("sub/dst"));
}

test "copy: the permission bits of the source come with it" {
    var c = try kit.Case.init();
    defer c.deinit();
    for ([_]std.fs.File.Mode{ 0o755, 0o640, 0o600 }) |mode| {
        var f = try c.tmp.dir.createFile("exe", .{ .mode = mode });
        f.close();
        c.tmp.dir.deleteFile("copy") catch {};
        try kit.expectResult(try c.run(&.{ "copy", "exe", "copy" }), 0, "", "");
        const st = try c.tmp.dir.statFile("copy");
        try t.expectEqual(mode, st.mode & 0o777);
        c.tmp.dir.deleteFile("exe") catch {};
    }
}

test "copy: a source that is missing or is a directory is status 1, and nothing is written, nor an existing destination changed" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.run(&.{ "copy", "nope", "dst" }), 1, "", "check copy: cannot copy nope to dst: FileNotFound\n");
    try t.expect(!c.exists("dst"));
    try c.put("dst", "keep me");
    try kit.expectResult(try c.run(&.{ "copy", "nope", "dst" }), 1, "", "check copy: cannot copy nope to dst: FileNotFound\n");
    try t.expectEqualStrings("keep me", try c.read("dst"));
    try c.tmp.dir.makePath("d");
    try kit.expectFailure(try c.run(&.{ "copy", "d", "dst" }), 1, "check copy: cannot copy d to dst: ");
    try t.expectEqualStrings("keep me", try c.read("dst"));
    try kit.expectFailure(try c.run(&.{ "copy", "d", "fresh" }), 1, "check copy: cannot copy d to fresh: ");
    try t.expect(!c.exists("fresh"));
    // and no temporary file is left behind in the directory
    var seen: usize = 0;
    var it = c.tmp.dir.iterate();
    while (try it.next()) |_| seen += 1;
    try t.expectEqual(@as(usize, 2), seen);
}

test "copy: a destination in a directory that is not there is status 1; the wrong number of arguments is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("src", "x");
    try kit.expectFailure(try c.run(&.{ "copy", "src", "no-dir/dst" }), 1, "check copy: cannot copy src to no-dir/dst: ");
    const usage = "check copy: usage: check copy SOURCE DESTINATION\n";
    try kit.expectResult(try c.run(&.{"copy"}), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "copy", "src" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "copy", "a", "b", "c" }), 2, "", usage);
}

// ---- digest -----------------------------------------------------------------------------------------------------

test "digest: sha256 and sha512, as hex or as an integrity string, of a file; every form accepted writes the stamp" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    try c.put("empty", "");
    for ([_][]const u8{ "sha256:" ++ SHA256_ABC, "sha512:" ++ SHA512_ABC, SRI256_ABC, SRI512_ABC }) |want| {
        c.tmp.dir.deleteFile("o") catch {};
        try kit.expectResult(try c.run(&.{ "digest", "--out", "o", want, "abc", "the file" }), 0, "", "");
        try t.expectEqualStrings("ok\n", try c.read("o"));
    }
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_EMPTY, "empty", "e", "sha512:" ++ SHA512_EMPTY, "empty", "e" }), 0, "", "");
    // capital hex digits are the same digest
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, SHA256_ABC);
    try kit.expectResult(try c.run(&.{ "digest", try std.fmt.allocPrint(c.alloc(), "sha256:{s}", .{upper}), "abc", "x" }), 0, "", "");
}

test "digest: a longer file is read whole" {
    var c = try kit.Case.init();
    defer c.deinit();
    // a file of 100000 zero bytes: sha256 5f... is not memorized, so the same file is hashed under the same digest twice: equal files, equal digests;
    // one byte changed, another digest
    const zeros = try c.alloc().alloc(u8, 100000);
    @memset(zeros, 0);
    try c.put("z1", zeros);
    zeros[99999] = 1;
    try c.put("z2", zeros);
    const first = try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "z1", "z1" });
    try t.expectEqual(@as(u8, 1), first.status);
    // the message names the file's digest; the digest of z2 differs from z1's only if the last byte was read
    const marker = "the sha256 of z1 is ";
    const at = std.mem.indexOf(u8, first.err, marker).?;
    const z1_digest = first.err[at + marker.len .. at + marker.len + 64];
    const second = try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "z2", "z2" });
    const at2 = std.mem.indexOf(u8, second.err, "the sha256 of z2 is ").?;
    const z2_digest = second.err[at2 + "the sha256 of z2 is ".len ..][0..64];
    try t.expect(!std.mem.eql(u8, z1_digest, z2_digest));
    // and the first now matches what it printed
    const arg = try std.fmt.allocPrint(c.alloc(), "sha256:{s}", .{z1_digest});
    try kit.expectResult(try c.run(&.{ "digest", arg, "z1", "z1" }), 0, "", "");
}

test "digest: every mismatch is said by name with the digest the file has, the status is 1, and nothing is written" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    try c.put("other", "abd");
    const r = try c.run(&.{ "digest", "--out", "o", "sha256:" ++ SHA256_ABC, "abc", "good one", "sha256:" ++ SHA256_ABC, "other", "first bad", "sha512:" ++ SHA512_ABC, "other", "second bad" });
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expectEqualStrings("", r.out);
    var lines = std.mem.splitScalar(u8, r.err, '\n');
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    try t.expect(std.mem.startsWith(u8, l1, "check digest: first bad: the sha256 of other is "));
    try t.expect(std.mem.endsWith(u8, l1, "; expected " ++ SHA256_ABC));
    try t.expect(std.mem.startsWith(u8, l2, "check digest: second bad: the sha512 of other is "));
    try t.expect(std.mem.endsWith(u8, l2, "; expected " ++ SHA512_ABC));
    try t.expectEqualStrings("", lines.next().?);
    try t.expect(lines.next() == null);
    try t.expect(!c.exists("o"));
    // an earlier stamp stays as it was
    try c.put("o", "earlier");
    try t.expectEqual(@as(u8, 1), (try c.run(&.{ "digest", "--out", "o", "sha256:" ++ SHA256_ABC, "other", "x" })).status);
    try t.expectEqualStrings("earlier", try c.read("o"));
}

test "digest: a wrong digest of the wrong algorithm length or form is status 2; an unreadable file is status 1; the worst status wins" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    const form = "is not sha256:<hex>, sha512:<hex>, sha256-<base64> or sha512-<base64>";
    const bad = [_][]const u8{
        "sha256:" ++ SHA256_ABC ++ "00", // too long
        "sha256:" ++ SHA256_ABC[1..], // too short
        "sha512:" ++ SHA256_ABC, // sha256's digest under sha512
        "sha256:zz" ++ SHA256_ABC[2..], // not hex
        "md5:d41d8cd98f00b204e9800998ecf8427e",
        "sha1:da39a3ee5e6b4b0d3255bfef95601890afd80709",
        "sha256", // no digest at all
        "sha256-!!!!", // not base64
        "sha256-" ++ SRI512_ABC["sha512-".len..], // sha512's integrity under sha256
        "sha512-" ++ SRI256_ABC["sha256-".len..], // sha256's integrity under sha512
        "",
        "ba7816bf",
    };
    for (bad) |want| {
        const r = try c.run(&.{ "digest", want, "abc", "n" });
        if (r.status != 2 or std.mem.indexOf(u8, r.err, form) == null) {
            std.debug.print("'{s}': status {d}, stderr '{s}'\n", .{ want, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "nope", "missing one" }), 1, "", "check digest: missing one: cannot read nope: FileNotFound\n");
    try c.tmp.dir.makePath("d");
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "d", "a dir" }), 1, "", "check digest: a dir: cannot read d: IsDir\n");
    // a wrong form and an unreadable file in one command: 2
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "nope", "a", "md5:x", "abc", "b" })).status);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "digest", "md5:x", "abc", "b", "sha256:" ++ SHA256_ABC, "nope", "a" })).status);
}

test "digest: the command line is options and then triples; anything else is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    const usage = "check digest: usage: check digest [--out FILE] [--stamp TEXT] (EXPECTED FILE NAME)...\n";
    try kit.expectResult(try c.run(&.{"digest"}), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "digest", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "abc" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "abc", "n", "x" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "digest", "--bogus", "v", "sha256:" ++ SHA256_ABC, "abc", "n" }), 2, "", "check digest: unknown option --bogus\n");
    try kit.expectResult(try c.run(&.{ "digest", "--out" }), 2, "", "check digest: --out needs a value\n");
}

test "digest: with no --out nothing is written; --stamp is what is; an unwritable stamp is status 1" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    try kit.expectResult(try c.run(&.{ "digest", "sha256:" ++ SHA256_ABC, "abc", "n" }), 0, "", "");
    var seen: usize = 0;
    var it = c.tmp.dir.iterate();
    while (try it.next()) |_| seen += 1;
    try t.expectEqual(@as(usize, 1), seen);
    try kit.expectResult(try c.run(&.{ "digest", "--stamp", "{\"status\": \"success\"}", "--out", "o", "sha256:" ++ SHA256_ABC, "abc", "n" }), 0, "", "");
    try t.expectEqualStrings("{\"status\": \"success\"}", try c.read("o"));
    try kit.expectFailure(try c.run(&.{ "digest", "--out", "no-dir/o", "sha256:" ++ SHA256_ABC, "abc", "n" }), 1, "check digest: cannot write no-dir/o: temporary file: FileNotFound");
}

test "same: a second file that cannot be read after the first could is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try c.tmp.dir.makePath("d");
    try kit.expectResult(try c.run(&.{ "same", "--out", "o", "a", "d" }), 2, "", "check same: cannot compare a and d: IsDir\n");
}

test "digest: an integrity string that is not base64 of the right shape is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    for ([_][]const u8{ "sha256-A", "sha256-" ++ "!" ** 43 ++ "=", "sha512-" ++ "!" ** 86 ++ "==" }) |want| {
        try kit.expectFailure(try c.run(&.{ "digest", want, "abc", "n" }), 2, "is not sha256:<hex>");
    }
}

test "digest: the FIPS 180 test vectors of a million 'a', which no chunk size of the reader may change" {
    var c = try kit.Case.init();
    defer c.deinit();
    const million = try c.alloc().alloc(u8, 1_000_000);
    @memset(million, 'a');
    try c.put("million", million);
    const sha256 = "sha256:cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
    const sha512 = "sha512:e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b";
    try kit.expectResult(try c.run(&.{ "digest", sha256, "million", "a", sha512, "million", "b" }), 0, "", "");
    // and a file one byte shorter is another digest
    try c.put("short", million[0 .. million.len - 1]);
    try kit.expectFailure(try c.run(&.{ "digest", sha256, "short", "a" }), 1, "the sha256 of short is ");
}
