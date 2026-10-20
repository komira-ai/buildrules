//! scrub.zig: each detector goes red on a planted defect and stays green on the text it must allow. The words that are banned are
//! spelled in parts, so this file does not hold them.
const std = @import("std");
const S = @import("scrub.zig");
const t = std.testing;

const name_a = "ad" ++ "i";
const name_b = "Sur" ++ "esh";
const proj = "Kom" ++ "ira";
const plane = "k" ++ "bf";
const y25 = "20" ++ "25";
const y24 = "20" ++ "24";
const y26 = "20" ++ "26";
const grpc = "grpc:" ++ "//";

fn hitsOf(a: std.mem.Allocator, file: []const u8, text: []const u8) ![]S.Hit {
    var hs = std.ArrayList(S.Hit).empty;
    try S.scanText(a, file, text, &hs);
    return hs.items;
}

fn bad(a: std.mem.Allocator, text: []const u8) !usize {
    var n: usize = 0;
    for (try hitsOf(a, "f.txt", text)) |h| {
        if (h.allowed == null) n += 1;
    }
    return n;
}

test "scrub: a planted personal name is a hit, in either case, only as a word" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 1), try bad(a, "owner: " ++ name_a ++ "\n"));
    try t.expectEqual(@as(usize, 1), try bad(a, "owner: " ++ name_b ++ " wrote it\n"));
    try t.expectEqual(@as(usize, 1), try bad(a, "by AD" ++ "ITYA"));
    // a word that merely contains a name is not a hit
    try t.expectEqual(@as(usize, 0), try bad(a, "radix and badiness and the admiral\n"));
}

test "scrub: a planted date before 2026-09-01 is a hit in every spelling; later dates and plain numbers are not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const spellings = [_][]const u8{ "released " ++ y25 ++ "-02-20.", "released " ++ y25 ++ "0220.", "since Feb " ++ y25, "since February " ++ y25, "on Feb 20, " ++ y25, "on 20 Feb " ++ y25, "in " ++ y24, "in " ++ y25, "on " ++ y26 ++ "-08-31", "Aug " ++ y26, "20" ++ "21/05/04", "March 20" ++ "19" };
    for (spellings) |sp| try t.expectEqual(@as(usize, 1), try bad(a, sp));
    const fine = [_][]const u8{ "released " ++ y26 ++ "-09-01.", "on " ++ y26 ++ "-10-19", "Oct " ++ y26, "version " ++ y25 ++ ".1", "size " ++ y25 ++ "0", "id 12345678", "port 2048", "sha 4d91de4e4a" ++ y25 ++ "b" };
    for (fine) |f| try t.expectEqual(@as(usize, 0), try bad(a, f));
}

test "scrub: a Rust edition is reported as allowed, with the reason; the date of a pinned artifact is a hit" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const hs = try hitsOf(a, "f.txt", "edition = \"" ++ y24 ++ "\"");
    try t.expectEqual(@as(usize, 1), hs.len);
    try t.expect(hs[0].allowed != null);
    const hits = [_][]const u8{ "date = \"" ++ y25 ++ "-04-03\"", "\"date\": \"" ++ y25 ++ "-02-20\",", "rustc 1.85.0 (4d91de4e4 " ++ y25 ++ "-02-17)", "https://static.rust-lang.org/dist/" ++ y25 ++ "-02-20/x.tar.xz", "{\"pubtime\":\"20" ++ "23-08-20T18:56:11Z\"}", "we started on " ++ y25 ++ "-02-20 and shipped" };
    for (hits) |h| try t.expectEqual(@as(usize, 1), try bad(a, h));
}

test "scrub: LICENSE is not scanned for dates (its own text carries one); it is scanned for everything else" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 0), (try hitsOf(a, "LICENSE", "Version 2.0, January 20" ++ "04\n")).len);
    try t.expectEqual(@as(usize, 1), (try hitsOf(a, "LICENSE", "Copyright " ++ name_a ++ "\n")).len);
}

test "scrub: emails, home paths, private hosts, IP addresses and endpoints" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 1), try bad(a, "mail me" ++ "@example.org now"));
    try t.expectEqual(@as(usize, 1), try bad(a, "path /ho" ++ "me/someone/x"));
    try t.expectEqual(@as(usize, 1), try bad(a, "host box.tail1234.ts" ++ ".net"));
    try t.expectEqual(@as(usize, 1), try bad(a, "ip 10." ++ "1.2.3 here"));
    try t.expectEqual(@as(usize, 2), try bad(a, "engine = " ++ grpc ++ "10." ++ "1.2.3:8980")); // the address and the endpoint
    try t.expectEqual(@as(usize, 1), try bad(a, "engine = " ++ grpc ++ "buildfarm.example.org:8980"));
    // allowed: loopback, the documentation ranges, placeholders, versions, scoped npm names
    try t.expectEqual(@as(usize, 0), try bad(a, "http://127.0.0.1:8080 192.0.2.7 198.51.100.1 203.0.113.9 " ++ grpc ++ "re.example.invalid:8980 " ++ grpc ++ "<host>:1"));
    try t.expectEqual(@as(usize, 0), try bad(a, "pkg@1.2.3 and @types/node@20.1.2.3x and v1.2.3.4rc and git+ssh://git@host.org/x.git and http://u@h.org/"));
}

test "scrub: the control-plane vocabulary and the origin project's name are hits; the two public repository paths are not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 1), try bad(a, "the " ++ plane ++ " pool"));
    try t.expectEqual(@as(usize, 1), try bad(a, "the " ++ proj ++ " rules"));
    try t.expectEqual(@as(usize, 1), try bad(a, "see " ++ proj ++ "_core"));
    try t.expectEqual(@as(usize, 1), try bad(a, "git clone https://github.com/" ++ proj ++ "-ai/other"));
    try t.expectEqual(@as(usize, 0), try bad(a, "git clone https://github.com/" ++ proj ++ "-ai/buildrules"));
    try t.expectEqual(@as(usize, 0), try bad(a, "[source](https://github.com/" ++ proj ++ "-ai/buildrules/issues) and \"https://github.com/" ++ proj ++ "-ai/buildrules\" 'https://github.com/" ++ proj ++ "-ai/buildrules.git' https://github.com/" ++ proj ++ "-ai/buildrules x"));
    try t.expectEqual(@as(usize, 1), try bad(a, "github.com/" ++ proj ++ "-ai/mopm"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/mopm"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/mopm/issues"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/mopm/releases"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/buildrules.gitx"));
    try t.expectEqual(@as(usize, 1), try bad(a, "http://github.com/" ++ proj ++ "-ai/buildrules"));
    // not the whole URL: another host, a longer name, a different repository of the organisation
    try t.expectEqual(@as(usize, 1), try bad(a, "https://gitlab.com/" ++ proj ++ "-ai/buildrules"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/buildrules-evil"));
    try t.expectEqual(@as(usize, 1), try bad(a, "https://github.com/" ++ proj ++ "-ai/mopm_x"));
    try t.expectEqual(@as(usize, 1), try bad(a, "buildrules " ++ proj ++ "-ai/buildrules"));
    try t.expectEqual(@as(usize, 0), try bad(a, "https://github.com/" ++ proj ++ "-ai/mopm/releases/download/v0.0.1/x.tar.gz"));
    try t.expectEqual(@as(usize, 1), try bad(a, "ask the C" ++ "EO"));
    try t.expectEqual(@as(usize, 0), try bad(a, "the ceo-less case: CEOs? no: Ceolin"));
}

test "scrub: an author's address is allowed only in a file named package-lock.json, on a deprecated line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const line = "\"deprecated\": \"contact i" ++ "@izs.me\",";
    const hs = try hitsOf(a, "site/package-lock.json", line);
    try t.expect(hs.len == 1 and hs[0].allowed != null);
    try t.expectEqual(@as(usize, 1), (try hitsOf(a, "site/not-package-lock.json", line)).len);
    try t.expectEqual(@as(usize, 1), (try hitsOf(a, "site/package-lock.json", "\"name\": \"x\", \"author\": \"i" ++ "@izs.me\"")).len);
    try t.expectEqual(@as(usize, 1), (try hitsOf(a, "README.md", line)).len);
}

test "scrub: binary files are recognised and a clean text has no hit" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect(S.isBinary("abc\x00def"));
    try t.expect(!S.isBinary("plain text\n"));
    try t.expectEqual(@as(usize, 0), (try hitsOf(a, "README.md", "# buildrules\n\nHermetic Buck2 rules. Apache-2.0.\n")).len);
}
