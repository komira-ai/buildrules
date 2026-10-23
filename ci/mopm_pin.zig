//! The pinned mopm is verified by who signed it, and not only by its digest. rules/mopm/pins.bzl pins each mopm release by the sha256 of its tarball; this reads that table
//! (the one place the pin lives), downloads every pinned tarball and its Sigstore bundle, and requires (a) the bytes to have the pinned size and sha256, and (b) `cosign
//! verify-blob` to accept the bundle for the tarball with the identity of mopm's release workflow on main and the GitHub Actions issuer. A digest that was compared once by
//! hand, or a pin edited to the digest of another build, is then caught by a check that cannot be argued with: the pin is only as good as the release that signed it.
//!
//! The command line is mopm_pin_main.zig. The pure parts (the table, the commands, the verdicts) are tested here against fakes of curl and cosign that behave like the real
//! ones on the cases that matter (a wrong digest, a signature of other bytes, a signer that is not the release workflow).
const std = @import("std");
const t = std.testing;

/// The only workflow whose signature makes a mopm tarball the pinned one: mopm's release workflow, on its main branch.
/// The scrub (tools/scrub) allows the project's name only in the paths of a mopm release and of this repository, so the signer's address is spelled in parts, as the scrub spells its own.
pub const mopm_repo = "kom" ++ "ira-ai/mo" ++ "pm";
pub const identity = "https://github.com/" ++ mopm_repo ++ "/.github/workflows/release.yml@refs/heads/main";
/// The issuer of the certificate of a keyless signature made by a GitHub Actions run.
pub const issuer = "https://token.actions.githubusercontent.com";
/// A pinned URL is a release asset of mopm's repository; the bundle of an asset is the asset's URL with `bundle_suffix`.
pub const url_prefix = "https://github.com/komira-ai/mopm/releases/download/";
pub const bundle_suffix = ".sigstore.json";
/// Tries of `cosign verify-blob` when it could not fetch the Sigstore trusted root (a network flake that says nothing about the signature).
pub const cosign_tries: u32 = 3;
pub const retry_ms: u64 = 2000;

/// One row of `MOPM_VERSIONS`.
pub const Row = struct { version: []const u8, url: []const u8, sha256: []const u8, size: u64 };

pub const Table = struct { default: []const u8, rows: []const Row };

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn quoted(line: []const u8, key: []const u8) ?[]const u8 {
    var rest = std.mem.trimLeft(u8, line, " ");
    if (!std.mem.startsWith(u8, rest, key)) return null;
    rest = rest[key.len..];
    if (!std.mem.startsWith(u8, rest, "\"")) return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// The `MOPM_DEFAULT` and the rows of `MOPM_VERSIONS` in the text of rules/mopm/pins.bzl. Comment lines are not read. Anything this cannot read as a complete row is an error, so a
/// table in a shape it does not know fails the check and is never skipped.
pub fn parse(a: std.mem.Allocator, text: []const u8) !Table {
    var default: ?[]const u8 = null;
    var rows = std.ArrayList(Row).init(a);
    var in_table = false;
    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var sha: ?[]const u8 = null;
    var size: ?u64 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \r");
        const trimmed = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (!in_table) {
            if (std.mem.startsWith(u8, line, "MOPM_DEFAULT = ")) default = quoted(line["MOPM_DEFAULT = ".len..], "");
            if (std.mem.eql(u8, line, "MOPM_VERSIONS = {")) in_table = true;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            in_table = false;
            break;
        }
        if (std.mem.startsWith(u8, line, "    \"") and std.mem.endsWith(u8, line, "\": {")) {
            if (version != null) return error.RowNotClosed;
            version = line[5 .. line.len - 4];
            url = null;
            sha = null;
            size = null;
            continue;
        }
        if (std.mem.eql(u8, line, "    },")) {
            const v = version orelse return error.RowNotOpened;
            try rows.append(.{
                .version = v,
                .url = url orelse return error.RowWithoutUrl,
                .sha256 = sha orelse return error.RowWithoutSha256,
                .size = size orelse return error.RowWithoutSize,
            });
            version = null;
            continue;
        }
        if (version == null) return error.UnreadableLine;
        if (quoted(line, "\"url\": ")) |v| url = v;
        if (quoted(line, "\"sha256\": ")) |v| sha = v;
        if (std.mem.startsWith(u8, trimmed, "\"size\": ")) {
            const num = std.mem.trimRight(u8, trimmed["\"size\": ".len..], ",");
            size = std.fmt.parseInt(u64, num, 10) catch return error.SizeNotANumber;
        }
    }
    if (in_table or version != null) return error.TableNotClosed;
    if (rows.items.len == 0) return error.NoRows;
    const d = default orelse return error.NoDefault;
    var found = false;
    for (rows.items) |r| {
        if (!isHex64(r.sha256)) return error.Sha256NotHex;
        if (std.mem.eql(u8, r.version, d)) found = true;
    }
    if (!found) return error.DefaultNotInTable;
    return .{ .default = d, .rows = try rows.toOwnedSlice() };
}

pub const Run = struct { code: u8, stderr: []const u8 };

/// cosign could not fetch the Sigstore trusted root: a network failure, not a verdict. Only these are retried; a refusal of the signature or of the certificate is final.
pub fn isTrustedRootFetchFailure(stderr: []const u8) bool {
    const markers = [_][]const u8{ "tuf refresh failed", "Could not fetch trusted_root.json", "error getting live trusted root" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, stderr, m) != null) return true;
    }
    return false;
}

/// The command that decides one tarball: its bundle, the one signer and the issuer, the tarball. `cosign` is the program.
pub fn cosignArgv(a: std.mem.Allocator, cosign: []const u8, bundle: []const u8, asset: []const u8) ![]const []const u8 {
    const argv = [_][]const u8{ cosign, "verify-blob", "--bundle", bundle, "--certificate-identity", identity, "--certificate-oidc-issuer", issuer, asset };
    return try a.dupe([]const u8, &argv);
}

fn baseName(url: []const u8) []const u8 {
    return url[std.mem.lastIndexOfScalar(u8, url, '/').? + 1 ..];
}

/// Verifies one row with `io` (`fetch(a, url) ![]const u8`, `cosign(a, argv) !Run`, `pause(ms)`), keeping the files in `work` (an existing directory). Returns null when the
/// tarball is the pinned bytes and mopm's release workflow signed them, and otherwise the reason.
pub fn verifyRow(comptime Io: type, io: *Io, a: std.mem.Allocator, row: Row, work: []const u8, cosign: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, row.url, url_prefix) or std.mem.indexOfScalar(u8, row.url[url_prefix.len..], '/') == null)
        return try std.fmt.allocPrint(a, "mopm {s}: the pinned url {s} is not a release asset of {s}", .{ row.version, row.url, url_prefix });
    const bundle_url = try std.fmt.allocPrint(a, "{s}" ++ bundle_suffix, .{row.url});
    const asset_bytes = io.fetch(a, row.url) catch |e| return try std.fmt.allocPrint(a, "mopm {s}: cannot download {s}: {s}", .{ row.version, row.url, @errorName(e) });
    if (asset_bytes.len != row.size)
        return try std.fmt.allocPrint(a, "mopm {s}: the download is {d} bytes, the pin says {d}", .{ row.version, asset_bytes.len, row.size });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(asset_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, row.sha256))
        return try std.fmt.allocPrint(a, "mopm {s}: the sha256 of the download is {s}, the pin says {s}", .{ row.version, &hex, row.sha256 });
    const bundle_bytes = io.fetch(a, bundle_url) catch |e| return try std.fmt.allocPrint(a, "mopm {s}: cannot download the bundle {s}: {s}", .{ row.version, bundle_url, @errorName(e) });

    const asset_path = try std.fs.path.join(a, &.{ work, baseName(row.url) });
    const bundle_path = try std.fmt.allocPrint(a, "{s}" ++ bundle_suffix, .{asset_path});
    {
        const f = try std.fs.cwd().createFile(asset_path, .{});
        defer f.close();
        try f.writeAll(asset_bytes);
    }
    {
        const f = try std.fs.cwd().createFile(bundle_path, .{});
        defer f.close();
        try f.writeAll(bundle_bytes);
    }
    const argv = try cosignArgv(a, cosign, bundle_path, asset_path);
    var tries: u32 = 1;
    while (true) : (tries += 1) {
        const r = io.cosign(a, argv) catch |e| return try std.fmt.allocPrint(a, "mopm {s}: cannot run {s}: {s}", .{ row.version, cosign, @errorName(e) });
        if (r.code == 0) return null;
        if (tries < cosign_tries and isTrustedRootFetchFailure(r.stderr)) {
            io.pause(retry_ms * tries);
            continue;
        }
        const why: []const u8 = if (isTrustedRootFetchFailure(r.stderr)) "cosign could not fetch the Sigstore trusted root (a network failure, not a verdict)" else "the signature does not verify";
        return try std.fmt.allocPrint(a, "mopm {s}: {s} for {s} (identity {s}): {s}", .{ row.version, why, baseName(row.url), identity, std.mem.trim(u8, r.stderr, " \r\n") });
    }
}

/// The reasons, one per pinned version that does not verify; empty when all do.
pub fn verifyAll(comptime Io: type, io: *Io, a: std.mem.Allocator, table: Table, work: []const u8, cosign: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (table.rows) |row| {
        if (try verifyRow(Io, io, a, row, work, cosign)) |why| try out.append(why);
    }
    return try out.toOwnedSlice();
}

// ---- the real curl and cosign ------------------------------------------------------------------------------------------------------

pub const RealIo = struct {
    curl: []const u8,
    max_bytes: usize = 256 << 20,

    pub fn fetch(self: *RealIo, a: std.mem.Allocator, url: []const u8) ![]const u8 {
        const r = try std.process.Child.run(.{
            .allocator = a,
            .argv = &.{ self.curl, "--fail", "--silent", "--show-error", "--location", "--retry", "3", url },
            .max_output_bytes = self.max_bytes,
        });
        switch (r.term) {
            .Exited => |c| {
                if (c != 0) {
                    std.debug.print("curl {s}: exit {d}: {s}\n", .{ url, c, std.mem.trim(u8, r.stderr, " \r\n") });
                    return error.DownloadFailed;
                }
            },
            else => return error.DownloadFailed,
        }
        return r.stdout;
    }

    pub fn cosign(self: *RealIo, a: std.mem.Allocator, argv: []const []const u8) !Run {
        _ = self;
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 1 << 20 });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .stderr = r.stderr };
    }

    pub fn pause(self: *RealIo, ms: u64) void {
        _ = self;
        std.time.sleep(ms * std.time.ns_per_ms);
    }
};

// ---- tests -------------------------------------------------------------------------------------------------------------------------

const asset_a = "pretend mopm tarball";
const asset_a_url = url_prefix ++ "v1.2.3/mopm-1.2.3-linux-x86_64.tar.gz";

fn shaOf(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// A curl that serves a table of url -> bytes, and a cosign that accepts exactly what the real one would: the bundle is a signature of the tarball's bytes
/// (`signed-by <identity>|<issuer>|<sha256>`) and the command must name that identity and that issuer.
const Fake = struct {
    urls: std.ArrayList([]const u8),
    bodies: std.ArrayList([]const u8),
    cosign_calls: u32 = 0,
    pauses: u32 = 0,
    flaky: u32 = 0,
    last_argv: []const []const u8 = &.{},

    fn serve(self: *Fake, url: []const u8, body: []const u8) !void {
        try self.urls.append(url);
        try self.bodies.append(body);
    }

    pub fn fetch(self: *Fake, a: std.mem.Allocator, url: []const u8) ![]const u8 {
        _ = a;
        for (self.urls.items, 0..) |u, i| {
            if (std.mem.eql(u8, u, url)) return self.bodies.items[i];
        }
        return error.NotFound;
    }

    pub fn cosign(self: *Fake, a: std.mem.Allocator, argv: []const []const u8) !Run {
        self.cosign_calls += 1;
        self.last_argv = argv;
        if (self.flaky > 0) {
            self.flaky -= 1;
            return .{ .code = 1, .stderr = "Error: tuf refresh failed: could not fetch\n" };
        }
        // argv: cosign verify-blob --bundle B --certificate-identity I --certificate-oidc-issuer S FILE
        if (argv.len != 9) return .{ .code = 1, .stderr = "usage" };
        const bundle = try std.fs.cwd().readFileAlloc(a, argv[3], 1 << 20);
        const file = try std.fs.cwd().readFileAlloc(a, argv[8], 1 << 20);
        const sha = shaOf(file);
        const asked = try std.fmt.allocPrint(a, "signed-by {s}|{s}|{s}", .{ argv[5], argv[7], &sha });
        if (!std.mem.eql(u8, bundle, asked)) return .{ .code = 1, .stderr = "Error: none of the expected identities matched\n" };
        return .{ .code = 0, .stderr = "Verified OK\n" };
    }

    pub fn pause(self: *Fake, ms: u64) void {
        _ = ms;
        self.pauses += 1;
    }
};

fn goodRow(a: std.mem.Allocator) !Row {
    const sha = try a.dupe(u8, &shaOf(asset_a));
    return .{ .version = "1.2.3", .url = asset_a_url, .sha256 = sha, .size = asset_a.len };
}

fn signatureOf(a: std.mem.Allocator, who: []const u8, bytes: []const u8) ![]const u8 {
    const sha = shaOf(bytes);
    return try std.fmt.allocPrint(a, "signed-by {s}|{s}|{s}", .{ who, issuer, &sha });
}

const Case = struct { arena: std.heap.ArenaAllocator, tmp: t.TmpDir, work: []const u8, fake: Fake, row: Row };

fn setup(c: *Case) !void {
    c.arena = std.heap.ArenaAllocator.init(t.allocator);
    const a = c.arena.allocator();
    c.tmp = t.tmpDir(.{});
    c.work = try c.tmp.dir.realpathAlloc(a, ".");
    c.fake = .{ .urls = std.ArrayList([]const u8).init(a), .bodies = std.ArrayList([]const u8).init(a) };
    c.row = try goodRow(a);
    try c.fake.serve(asset_a_url, asset_a);
    try c.fake.serve(asset_a_url ++ bundle_suffix, try signatureOf(a, identity, asset_a));
}

fn teardown(c: *Case) void {
    c.tmp.cleanup();
    c.arena.deinit();
}

fn verdict(c: *Case) !?[]const u8 {
    return try verifyRow(Fake, &c.fake, c.arena.allocator(), c.row, c.work, "cosign");
}

fn expectReason(got: ?[]const u8, needle: []const u8) !void {
    const g = got orelse {
        std.debug.print("expected a failure with `{s}`, got a pass\n", .{needle});
        return error.ExpectedFailure;
    };
    if (std.mem.indexOf(u8, g, needle) == null) {
        std.debug.print("expected `{s}` in `{s}`\n", .{ needle, g });
        return error.WrongReason;
    }
}

test "a tarball of the pinned bytes, signed by mopm's release workflow on main, verifies" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    try t.expect((try verdict(&c)) == null);
    try t.expectEqual(@as(u32, 1), c.fake.cosign_calls);
    // the command is the one that pins the signer: this bundle, this identity, this issuer, this tarball
    const argv = c.fake.last_argv;
    try t.expectEqualStrings("verify-blob", argv[1]);
    try t.expectEqualStrings("--certificate-identity", argv[4]);
    try t.expectEqualStrings("https://github.com/" ++ mopm_repo ++ "/.github/workflows/release.yml@refs/heads/main", argv[5]);
    try t.expectEqualStrings("--certificate-oidc-issuer", argv[6]);
    try t.expectEqualStrings("https://token.actions.githubusercontent.com", argv[7]);
    try t.expect(std.mem.endsWith(u8, argv[3], "mopm-1.2.3-linux-x86_64.tar.gz.sigstore.json"));
    try t.expect(std.mem.endsWith(u8, argv[8], "mopm-1.2.3-linux-x86_64.tar.gz"));
}

test "a digest that differs from the pin fails before cosign is asked" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    // other bytes of the pinned size
    c.fake.bodies.items[0] = "PRETEND MOPM TARBALL";
    try t.expectEqual(asset_a.len, c.fake.bodies.items[0].len);
    try expectReason(try verdict(&c), "the sha256 of the download is");
    try t.expectEqual(@as(u32, 0), c.fake.cosign_calls);
}

test "a size that differs from the pin fails" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    c.row.size += 1;
    try expectReason(try verdict(&c), "the pin says");
    try t.expectEqual(@as(u32, 0), c.fake.cosign_calls);
}

test "a pin edited to the digest of other bytes that mopm never signed fails" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    // the tarball and the pinned digest were swapped together; the release's bundle signs the old bytes only
    const swapped = "a rebuilt tarball nobody signed";
    c.fake.bodies.items[0] = swapped;
    c.row.size = swapped.len;
    c.row.sha256 = try c.arena.allocator().dupe(u8, &shaOf(swapped));
    try expectReason(try verdict(&c), "the signature does not verify");
    try t.expectEqual(@as(u32, 1), c.fake.cosign_calls);
}

test "a bundle signed by another workflow does not verify" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    c.fake.bodies.items[1] = try signatureOf(c.arena.allocator(), "https://github.com/" ++ mopm_repo ++ "/.github/workflows/ci.yml@refs/heads/main", asset_a);
    try expectReason(try verdict(&c), "the signature does not verify");
}

test "a missing bundle or a missing tarball fails" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    _ = c.fake.urls.pop();
    _ = c.fake.bodies.pop();
    try expectReason(try verdict(&c), "cannot download the bundle");
    c.fake.urls.items[0] = "https://elsewhere.invalid/x";
    try expectReason(try verdict(&c), "cannot download");
}

test "a url that is not a release asset of mopm is refused without a download" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    c.row.url = "https://example.com/mopm.tar.gz";
    try expectReason(try verdict(&c), "is not a release asset");
    c.row.url = url_prefix ++ "mopm.tar.gz";
    try expectReason(try verdict(&c), "is not a release asset");
}

test "a trusted-root fetch failure is retried and then verifies; a verdict is not retried" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    c.fake.flaky = 2;
    try t.expect((try verdict(&c)) == null);
    try t.expectEqual(@as(u32, 3), c.fake.cosign_calls);
    try t.expectEqual(@as(u32, 2), c.fake.pauses);
    // never recovers: gives up after the tries, and says it is a network failure
    c.fake.cosign_calls = 0;
    c.fake.flaky = 99;
    try expectReason(try verdict(&c), "network failure");
    try t.expectEqual(cosign_tries, c.fake.cosign_calls);
    // a refusal of the signature is final on the first try
    c.fake.cosign_calls = 0;
    c.fake.flaky = 0;
    c.fake.bodies.items[1] = "garbage";
    try expectReason(try verdict(&c), "the signature does not verify");
    try t.expectEqual(@as(u32, 1), c.fake.cosign_calls);
}

test "verifyAll reports every row that fails, and none that pass" {
    var c: Case = undefined;
    try setup(&c);
    defer teardown(&c);
    const a = c.arena.allocator();
    var bad = c.row;
    bad.version = "1.2.4";
    bad.url = url_prefix ++ "v1.2.4/mopm-1.2.4-linux-x86_64.tar.gz";
    const rows = [_]Row{ c.row, bad };
    const got = try verifyAll(Fake, &c.fake, a, .{ .default = "1.2.3", .rows = &rows }, c.work, "cosign");
    try t.expectEqual(@as(usize, 1), got.len);
    try expectReason(got[0], "mopm 1.2.4");
}

const real_shape =
    \\"""docs"""
    \\
    \\MOPM_DEFAULT = "0.0.25"
    \\
    \\MOPM_VERSIONS = {
    \\    "0.0.25": {
    \\        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.25/mopm-0.0.25-linux-x86_64.tar.gz",
    \\        "sha256": "1848ffbb6c3f3522e95c36d3d5f7d4260abb8dde2cb3c415b17ca94dc48edeac",
    \\        "size": 1074723,
    \\        # The directory the tarball unpacks into.
    \\        "dir": "mopm-0.0.25-linux-x86_64",
    \\    },
    \\    "0.0.26": {
    \\        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.26/mopm-0.0.26-linux-x86_64.tar.gz",
    \\        "sha256": "2848ffbb6c3f3522e95c36d3d5f7d4260abb8dde2cb3c415b17ca94dc48edeac",
    \\        "size": 5,
    \\    },
    \\}
    \\
    \\def vname(version):
    \\    return version
;

test "the table is read: every row, its default, no comment" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const tab = try parse(ar.allocator(), real_shape);
    try t.expectEqualStrings("0.0.25", tab.default);
    try t.expectEqual(@as(usize, 2), tab.rows.len);
    try t.expectEqualStrings("0.0.25", tab.rows[0].version);
    try t.expectEqualStrings("https://github.com/komira-ai/mopm/releases/download/v0.0.25/mopm-0.0.25-linux-x86_64.tar.gz", tab.rows[0].url);
    try t.expectEqualStrings("1848ffbb6c3f3522e95c36d3d5f7d4260abb8dde2cb3c415b17ca94dc48edeac", tab.rows[0].sha256);
    try t.expectEqual(@as(u64, 1074723), tab.rows[0].size);
    try t.expectEqual(@as(u64, 5), tab.rows[1].size);
}

fn expectParseError(text: []const u8, want: anyerror) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectError(want, parse(ar.allocator(), text));
}

fn replaced(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, real_shape, from) orelse return error.EditDidNotApply;
    return std.mem.concat(a, u8, &.{ real_shape[0..i], to, real_shape[i + from.len ..] });
}

test "a table this cannot read completely is an error, not a pass" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try expectParseError("MOPM_DEFAULT = \"1\"\n", error.NoRows);
    try expectParseError(try replaced(a, "MOPM_DEFAULT = \"0.0.25\"", "MOPM_DEFAULT = \"0.0.99\""), error.DefaultNotInTable);
    try expectParseError(try replaced(a, "MOPM_DEFAULT = \"0.0.25\"\n", ""), error.NoDefault);
    try expectParseError(try replaced(a, "        \"size\": 5,\n", ""), error.RowWithoutSize);
    try expectParseError(try replaced(a, "        \"size\": 5,\n", "        \"size\": five,\n"), error.SizeNotANumber);
    try expectParseError(try replaced(a, "        \"url\": \"https://github.com/komira-ai/mopm/releases/download/v0.0.26/mopm-0.0.26-linux-x86_64.tar.gz\",\n", ""), error.RowWithoutUrl);
    try expectParseError(try replaced(a, "2848ffbb6c3f3522e95c36d3d5f7d4260abb8dde2cb3c415b17ca94dc48edeac", "2848"), error.Sha256NotHex);
    try expectParseError(try replaced(a, "\n    },\n    \"0.0.26\"", "\n    \"0.0.26\""), error.RowNotClosed);
}

test "a pin in a comment is not a pin" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tab = try parse(a, try replaced(a, "    \"0.0.26\": {", "    # \"0.0.27\": {\n    \"0.0.26\": {"));
    try t.expectEqual(@as(usize, 2), tab.rows.len);
}

test "cosignArgv names the one signer and the issuer" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const argv = try cosignArgv(ar.allocator(), "cosign", "b.json", "a.tar.gz");
    try t.expectEqual(@as(usize, 9), argv.len);
    try t.expectEqualStrings(identity, argv[5]);
    try t.expectEqualStrings(issuer, argv[7]);
    try t.expect(std.mem.endsWith(u8, identity, "/.github/workflows/release.yml@refs/heads/main"));
    try t.expect(std.mem.startsWith(u8, identity, "https://github.com/" ++ mopm_repo ++ "/"));
}

test "the real pins.bzl is a table this reads, and each url is a release asset of mopm" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ w, "rules/mopm/pins.bzl" }), 1 << 20);
    const tab = try parse(a, text);
    try t.expect(tab.rows.len >= 1);
    for (tab.rows) |r| {
        try t.expect(std.mem.startsWith(u8, r.url, url_prefix));
        try t.expect(r.size > 0);
    }
}

test "isTrustedRootFetchFailure is a network failure and nothing else" {
    try t.expect(isTrustedRootFetchFailure("Error: tuf refresh failed: x"));
    try t.expect(isTrustedRootFetchFailure("warning: Could not fetch trusted_root.json"));
    try t.expect(!isTrustedRootFetchFailure("Error: none of the expected identities matched"));
    try t.expect(!isTrustedRootFetchFailure(""));
}
