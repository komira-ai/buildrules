//! What the keyring-rotation proof reads out of other programs' words, as pure functions of their text: `gpg --with-colons` listings (which key is the signing subkey),
//! `gpg --list-packets` (who signed), the status lines of `gpgv --status-fd` (which signatures were good), the deb822 source apt is given, and the verdict on an `apt-get`
//! run. They run nothing; `../apt_rotation.zig` runs the programs and asks these.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ NoPrimaryKey, NoSigningSubkey };

pub const Keys = struct {
    /// The fingerprint of the certifying primary key (the one a keyring file is exported by).
    primary: []const u8,
    /// The fingerprint of its signing subkey (the one `--local-user <fingerprint>!` names).
    signing: []const u8,
};

/// The fields of one `--with-colons` record, split at colons.
fn field(line: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, line, ':');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == n) return f;
    }
    return "";
}

/// The fingerprint of the first primary key of a `--with-colons` listing (the `fpr` record after `sec`), or null when there is none: what a key that has no subkey yet is
/// asked for.
pub fn primaryFpr(colons: []const u8) ?[]const u8 {
    var after_sec = false;
    var it = std.mem.splitScalar(u8, colons, '\n');
    while (it.next()) |line| {
        const kind = field(line, 0);
        if (std.mem.eql(u8, kind, "sec")) {
            after_sec = true;
        } else if (std.mem.eql(u8, kind, "fpr") and after_sec) {
            return field(line, 9);
        } else {
            after_sec = false;
        }
    }
    return null;
}

/// The primary key's fingerprint and its signing subkey's, from the output of `gpg --list-secret-keys --with-colons`: the `fpr` record after `sec`, and the one after
/// an `ssb` whose capabilities (field 12) include `s`.
pub fn parseKeys(colons: []const u8) Error!Keys {
    var primary: ?[]const u8 = null;
    var signing: ?[]const u8 = null;
    var last: enum { none, sec, ssb_sign, ssb_other } = .none;
    var it = std.mem.splitScalar(u8, colons, '\n');
    while (it.next()) |line| {
        const kind = field(line, 0);
        if (std.mem.eql(u8, kind, "sec")) {
            last = .sec;
        } else if (std.mem.eql(u8, kind, "ssb")) {
            last = if (std.mem.indexOfScalar(u8, field(line, 11), 's') != null) .ssb_sign else .ssb_other;
        } else if (std.mem.eql(u8, kind, "fpr")) {
            const fpr = field(line, 9);
            switch (last) {
                .sec => if (primary == null) {
                    primary = fpr;
                },
                .ssb_sign => if (signing == null) {
                    signing = fpr;
                },
                else => {},
            }
            last = .none;
        }
    }
    return .{ .primary = primary orelse return error.NoPrimaryKey, .signing = signing orelse return error.NoSigningSubkey };
}

/// The long key id (16 hex digits) of a v4 fingerprint: its last 16 digits. This is what a signature names as its issuer.
pub fn keyId(fpr: []const u8) []const u8 {
    return if (fpr.len > 16) fpr[fpr.len - 16 ..] else fpr;
}

/// The issuers of the signature packets of `gpg --list-packets` output, in order: the `keyid` of each `:signature packet:` line.
pub fn signers(a: Allocator, packets: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, packets, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, ":signature packet:")) continue;
        const at = std.mem.indexOf(u8, line, "keyid ") orelse continue;
        const rest = line[at + "keyid ".len ..];
        const end = std.mem.indexOfAny(u8, rest, ", \r") orelse rest.len;
        try out.append(rest[0..end]);
    }
    return out.items;
}

/// What `gpgv --status-fd 1` said about the signatures of one file.
pub const Verdict = struct {
    /// The key ids of the `GOODSIG` lines.
    good: []const []const u8,
    /// The key ids of the `NO_PUBKEY` lines: signatures the keyring could not check.
    missing: []const []const u8,
    /// The number of `BADSIG` lines.
    bad: usize,
};

pub fn verdict(a: Allocator, status: []const u8) !Verdict {
    var good = std.ArrayList([]const u8).init(a);
    var missing = std.ArrayList([]const u8).init(a);
    var bad: usize = 0;
    var it = std.mem.splitScalar(u8, status, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        const tag = "[GNUPG:] ";
        if (!std.mem.startsWith(u8, line, tag)) continue;
        var words = std.mem.tokenizeScalar(u8, line[tag.len..], ' ');
        const what = words.next() orelse continue;
        if (std.mem.eql(u8, what, "GOODSIG")) {
            if (words.next()) |id| try good.append(id);
        } else if (std.mem.eql(u8, what, "NO_PUBKEY")) {
            if (words.next()) |id| try missing.append(id);
        } else if (std.mem.eql(u8, what, "BADSIG")) {
            bad += 1;
        }
    }
    return .{ .good = good.items, .missing = missing.items, .bad = bad };
}

/// Whether `ids` holds exactly the id `want` once and nothing else.
pub fn onlyId(ids: []const []const u8, want: []const u8) bool {
    return ids.len == 1 and std.ascii.eqlIgnoreCase(ids[0], want);
}

/// Whether `ids` holds `want` (case does not matter).
pub fn hasId(ids: []const []const u8, want: []const u8) bool {
    for (ids) |id| {
        if (std.ascii.eqlIgnoreCase(id, want)) return true;
    }
    return false;
}

/// The same two ids, in either order, and nothing else.
pub fn sameTwo(ids: []const []const u8, x: []const u8, y: []const u8) bool {
    return ids.len == 2 and hasId(ids, x) and hasId(ids, y) and !std.ascii.eqlIgnoreCase(ids[0], ids[1]);
}

/// The deb822 source file apt is given: the repository at `uri` (suite `stable`, component `main`), trusted through the keyring file `keyring` and no other.
pub fn sourcesFile(a: Allocator, uri: []const u8, keyring: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "Types: deb\nURIs: {s}\nSuites: stable\nComponents: main\nSigned-By: {s}\n", .{ uri, keyring });
}

/// The lines of an `apt-get` run's output that start with `W:` or `E:`.
pub fn problems(a: Allocator, output: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "W:") or std.mem.startsWith(u8, line, "E:")) try out.append(line);
    }
    return out.items;
}

/// Whether apt's words say the signature is why the repository was refused (its key is not in the keyring it was given, or the Release is not signed by it), and not some other
/// failure such as an address that does not resolve.
pub fn refusedForSignature(output: []const u8) bool {
    for ([_][]const u8{ "NO_PUBKEY", "is not signed", "couldn't be verified" }) |w| {
        if (std.mem.indexOf(u8, output, w) != null) return true;
    }
    return false;
}

/// Whether a file name of apt's list directory is the `all` index of the repository (`..._main_binary-all_Packages`, with whatever compression suffix).
pub fn isAllIndex(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "_main_binary-all_Packages") != null;
}

const t = std.testing;

const colons_sample =
    "sec:u:255:22:AAAA111122223333:1700000000:::u:::scESC:::+::ed25519:::0:\n" ++
    "fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n" ++
    "grp:::::::::GRIP1:\n" ++
    "uid:u::::1700000000::HASH::apt-rotation-key-a::::::::::0:\n" ++
    "ssb:u:255:22:BBBB111122223333:1700000000::::::e:::+::ed25519::\n" ++
    "fpr:::::::::1111111111111111111111111111111111111111:\n" ++
    "grp:::::::::GRIP2:\n" ++
    "ssb:u:255:22:CCCC111122223333:1700000000::::::s:::+::ed25519::\n" ++
    "fpr:::::::::FEDCBA9876543210FEDCBA9876543210FEDCBA98:\n" ++
    "grp:::::::::GRIP3:\n";

test "parseKeys: the primary is the fpr after sec, the signing subkey the fpr after the ssb with capability s" {
    const k = try parseKeys(colons_sample);
    try t.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF01234567", k.primary);
    try t.expectEqualStrings("FEDCBA9876543210FEDCBA9876543210FEDCBA98", k.signing);
}

test "parseKeys: a key with an encryption subkey only has no signing subkey, and no sec record is no key" {
    const only_enc =
        "sec:u:255:22:AAAA111122223333:1700000000:::u:::scESC:::+::ed25519:::0:\n" ++
        "fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n" ++
        "ssb:u:255:22:BBBB111122223333:1700000000::::::e:::+::ed25519::\n" ++
        "fpr:::::::::1111111111111111111111111111111111111111:\n";
    try t.expectError(error.NoSigningSubkey, parseKeys(only_enc));
    try t.expectError(error.NoPrimaryKey, parseKeys(""));
    try t.expectError(error.NoPrimaryKey, parseKeys("fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n"));
}

test "primaryFpr: the fpr that follows sec, of a key with no subkey yet, and none when there is no sec" {
    try t.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF01234567", primaryFpr(colons_sample).?);
    try t.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", primaryFpr("sec:u:255:22:K:1700000000:::u:::cC:::+::ed25519:::0:\nfpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n").?);
    try t.expect(primaryFpr("") == null);
    try t.expect(primaryFpr("fpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:\n") == null);
    try t.expect(primaryFpr("sec:u:255:22:K:1700000000:::u:::cC:::+::ed25519:::0:\nuid:u::::1::H::x:\nfpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:\n") == null);
}

test "keyId is the last sixteen digits of a fingerprint" {
    try t.expectEqualStrings("FEDCBA9876543210", keyId("0123456789ABCDEF0123456789ABCDEFFEDCBA9876543210"));
    try t.expectEqualStrings("0123", keyId("0123"));
}

test "signers: one keyid per signature packet, in order, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const packets =
        ":signature packet: algo 22, keyid FEDCBA9876543210\n" ++
        "\tversion 4, created 1700000000, md5len 0, sigclass 0x00\n" ++
        "\tdigest algo 10, begin of digest ab cd\n" ++
        "\tsubpkt 33 len 21 (issuer fpr v4 FEDCBA9876543210FEDCBA9876543210FEDCBA98)\n" ++
        ":signature packet: algo 22, keyid 0123456789ABCDEF\n" ++
        "\tversion 4, created 1700000000, md5len 0, sigclass 0x00\n" ++
        ":signature packet: algo 22\n" ++
        ":literal data packet:\n";
    const got = try signers(a, packets);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("FEDCBA9876543210", got[0]);
    try t.expectEqualStrings("0123456789ABCDEF", got[1]);
    try t.expectEqual(@as(usize, 0), (try signers(a, "")).len);
}

test "verdict: good, missing and bad signatures are told apart" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const status =
        "[GNUPG:] NEWSIG\r\n" ++
        "[GNUPG:] KEY_CONSIDERED 0123456789ABCDEF0123456789ABCDEF01234567 0\n" ++
        "[GNUPG:] GOODSIG FEDCBA9876543210 apt-rotation-key-a\n" ++
        "[GNUPG:] ERRSIG 0123456789ABCDEF 22 10 00 1700000000 9 -\n" ++
        "[GNUPG:] NO_PUBKEY 0123456789ABCDEF\n" ++
        "[GNUPG:] BADSIG 1111111111111111 other\n" ++
        "[GNUPG:] GOODSIG\n" ++
        "[GNUPG:] NO_PUBKEY\n" ++
        "[GNUPG:]\n" ++
        "gpgv: not a status line GOODSIG 2222222222222222\n";
    const v = try verdict(a, status);
    try t.expectEqual(@as(usize, 1), v.good.len);
    try t.expectEqualStrings("FEDCBA9876543210", v.good[0]);
    try t.expectEqual(@as(usize, 1), v.missing.len);
    try t.expectEqualStrings("0123456789ABCDEF", v.missing[0]);
    try t.expectEqual(@as(usize, 1), v.bad);
}

test "the id comparisons: exactly one, containing, and the same two in either order" {
    try t.expect(onlyId(&.{"ab"}, "AB"));
    try t.expect(!onlyId(&.{ "ab", "cd" }, "ab"));
    try t.expect(!onlyId(&.{}, "ab"));
    try t.expect(!onlyId(&.{"cd"}, "ab"));
    try t.expect(hasId(&.{ "ab", "cd" }, "CD"));
    try t.expect(!hasId(&.{ "ab", "cd" }, "ef"));
    try t.expect(sameTwo(&.{ "ab", "cd" }, "cd", "ab"));
    try t.expect(!sameTwo(&.{ "ab", "ab" }, "ab", "cd"));
    try t.expect(!sameTwo(&.{ "ab", "ab" }, "ab", "ab"));
    try t.expect(!sameTwo(&.{ "ab", "cd", "ef" }, "ab", "cd"));
    try t.expect(!sameTwo(&.{ "ab", "ef" }, "ab", "cd"));
}

test "sourcesFile names the repository and exactly one keyring" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sourcesFile(a, "file:///x/repo", "/x/key.gpg");
    try t.expectEqualStrings("Types: deb\nURIs: file:///x/repo\nSuites: stable\nComponents: main\nSigned-By: /x/key.gpg\n", s);
}

test "problems: only the W: and E: lines, without their line ends" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try problems(a, "Get:1 file:/x stable InRelease\r\nW: something odd\r\nReading package lists...\nE: broken\n");
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("W: something odd", got[0]);
    try t.expectEqualStrings("E: broken", got[1]);
    try t.expectEqual(@as(usize, 0), (try problems(a, "Hit:1 file:/x stable InRelease\n")).len);
}

test "refusedForSignature: the three ways apt says the signature is why, and not an unrelated failure" {
    try t.expect(refusedForSignature("Err:1 file:/x stable InRelease\n  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF"));
    try t.expect(refusedForSignature("E: The repository 'file:/x stable InRelease' is not signed."));
    try t.expect(refusedForSignature("signatures couldn't be verified"));
    try t.expect(!refusedForSignature("E: Failed to fetch file:/nowhere  File not found"));
}

test "isAllIndex: the all index of the repository, plain or compressed, and no other" {
    try t.expect(isAllIndex("var_tmp_aptrot_repo_dists_stable_main_binary-all_Packages"));
    try t.expect(isAllIndex("var_tmp_aptrot_repo_dists_stable_main_binary-all_Packages.lz4"));
    try t.expect(!isAllIndex("var_tmp_aptrot_repo_dists_stable_main_binary-amd64_Packages"));
    try t.expect(!isAllIndex("var_tmp_aptrot_repo_dists_stable_InRelease"));
}
