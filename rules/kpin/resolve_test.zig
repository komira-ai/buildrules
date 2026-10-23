//! The offline core: what `lock` and `check` decide. Each test names the
//! defect it exists to catch.

const std = @import("std");
const fx = @import("fixtures.zig");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const pins = @import("pins.zig");
const resolve = @import("resolve.zig");
const Report = @import("diag.zig").Report;
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const toml_text =
    \\[tool]
    \\version = "1.0.0"
    \\url = "https://h.example/tool-{version}-{platform}.tar.gz"
    \\[tool.platform.linux-x86_64]
    \\[tool.platform.macos-aarch64]
    \\token = "darwin"
;

fn load(a: std.mem.Allocator, text: []const u8) ![]pins.Pin {
    var d = Diag.init(a);
    return pins.load(a, text, &d);
}

fn prevLock(a: std.mem.Allocator, version: []const u8, sha: []const u8) !lockfmt.Lock {
    const files = try a.dupe(lockfmt.File, &.{
        .{ .platform = "linux-x86_64", .url = "https://h.example/old", .sha256 = sha, .size = 3 },
        .{ .platform = "macos-aarch64", .url = "https://h.example/old", .sha256 = sha, .size = 3 },
    });
    const ps = try a.dupe(lockfmt.LockPin, &.{.{ .name = "tool", .version = version, .files = files }});
    return .{ .pins = ps };
}

test "with no hash anywhere the answer is `run kpin update`, never a guess" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    _ = try resolve.compute(a, .{ .pins = try load(a, toml_text) }, .{}, &rep);
    try t.expectEqual(@as(usize, 2), rep.errors.count());
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "kpin update") != null);
    try t.expectEqual(@as(usize, 0), rep.alarms.count());
}

test "hashes carry over from the lock; the URL follows the template and the token" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    const lock = try resolve.compute(a, .{ .pins = try load(a, toml_text) }, try prevLock(a, "1.0.0", fx.ABC_SHA256), &rep);
    try t.expect(rep.clean());
    const f = lockfmt.findFile(lock.pins[0], "macos-aarch64").?;
    try t.expectEqualStrings("https://h.example/tool-1.0.0-darwin.tar.gz", f.url);
    try t.expectEqualStrings(fx.ABC_SHA256, f.sha256);
}

test "a new version does not inherit the old version's hash" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    const bumped = try std.mem.replaceOwned(u8, a, toml_text, "1.0.0", "1.1.0");
    _ = try resolve.compute(a, .{ .pins = try load(a, bumped) }, try prevLock(a, "1.0.0", fx.ABC_SHA256), &rep);
    try t.expectEqual(@as(usize, 2), rep.errors.count());
    try t.expectEqual(@as(usize, 0), rep.alarms.count());
}

test "ALARM: pins.toml states a hash that contradicts the lock for the same version" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    const claimed = try std.fmt.allocPrint(a, "{s}\n[tool.platform.any]\nsha256 = \"{s}\"\nsize = 3\n", .{ toml_text, try fx.sha256Hex(a, "abd") });
    // `any` is a platform the lock lacks: it is new, not an alarm.
    _ = try resolve.compute(a, .{ .pins = try load(a, claimed) }, try prevLock(a, "1.0.0", fx.ABC_SHA256), &rep);
    try t.expect(rep.clean());
    // The same claim on a platform the lock has, with other bytes: an alarm.
    const text2 =
        \\[tool]
        \\version = "1.0.0"
        \\url = "https://h.example/tool-{version}-{platform}.tar.gz"
        \\[tool.platform.linux-x86_64]
        \\sha256 = "
    ;
    const full = try std.fmt.allocPrint(a, "{s}{s}\"\nsize = 3\n", .{ text2, try fx.sha256Hex(a, "abd") });
    var rep2 = Report.init(a);
    const lock = try resolve.compute(a, .{ .pins = try load(a, full) }, try prevLock(a, "1.0.0", fx.ABC_SHA256), &rep2);
    try t.expectEqual(@as(usize, 1), rep2.alarms.count());
    // The old bytes are not replaced by the new claim.
    try t.expectEqual(@as(usize, 0), lock.pins[0].files.len);
}

fn npmPkg(sri: []const u8) npm.Pkg {
    return .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://r.example/left-pad-1.3.0.tgz", .sri512 = sri };
}

fn prevNpm(a: std.mem.Allocator, sri: []const u8) !lockfmt.Lock {
    const n = try a.dupe(lockfmt.Npm, &.{.{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://r.example/old.tgz", .sri512 = sri, .sha256 = fx.ABC_SHA256, .size = 3 }});
    return .{ .npm = n };
}

test "npm: sha256 and size come from the lock, sri512 from package-lock.json" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    const lock = try resolve.compute(a, .{ .npm = &.{npmPkg(fx.ABC_SRI512)} }, try prevNpm(a, fx.ABC_SRI512), &rep);
    try t.expect(rep.clean());
    try t.expectEqualStrings(fx.ABC_SHA256, lock.npm[0].sha256);
    try t.expectEqualStrings(fx.ABC_SRI512, lock.npm[0].sri512);
    try t.expectEqualStrings("https://r.example/left-pad-1.3.0.tgz", lock.npm[0].url);
}

test "npm: a package the lock lacks needs update" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    _ = try resolve.compute(a, .{ .npm = &.{npmPkg(fx.ABC_SRI512)} }, .{}, &rep);
    try t.expectEqual(@as(usize, 1), rep.errors.count());
}

test "ALARM: package-lock.json now has another integrity for a version already locked" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var rep = Report.init(a);
    const other = try fx.sri512(a, fx.ABD);
    const lock = try resolve.compute(a, .{ .npm = &.{npmPkg(other)} }, try prevNpm(a, fx.ABC_SRI512), &rep);
    try t.expectEqual(@as(usize, 1), rep.alarms.count());
    try t.expectEqual(@as(usize, 0), rep.errors.count());
    try t.expectEqual(@as(usize, 0), lock.npm.len);
}

test "compareToPrevious: a hash edited in the lock itself is an alarm against the merge base" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try prevLock(a, "1.0.0", fx.ABC_SHA256);
    const edited = try prevLock(a, "1.0.0", try fx.sha256Hex(a, "abd"));
    var rep = Report.init(a);
    resolve.compareToPrevious(base, edited, &rep);
    try t.expectEqual(@as(usize, 2), rep.alarms.count());
    // Another version is a normal bump.
    var rep2 = Report.init(a);
    resolve.compareToPrevious(base, try prevLock(a, "1.1.0", try fx.sha256Hex(a, "abd")), &rep2);
    try t.expect(rep2.clean());
    // Unchanged is clean.
    var rep3 = Report.init(a);
    resolve.compareToPrevious(base, base, &rep3);
    try t.expect(rep3.clean());
    // npm: sha256 changed under one key.
    var n = (try prevNpm(a, fx.ABC_SRI512)).npm[0];
    n.sha256 = try fx.sha256Hex(a, "abd");
    var rep4 = Report.init(a);
    resolve.compareToPrevious(try prevNpm(a, fx.ABC_SRI512), .{ .npm = &.{n} }, &rep4);
    try t.expectEqual(@as(usize, 1), rep4.alarms.count());
}

test "compute: a template that does not expand is reported by pin and platform, and writes no file for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // pins.load refuses such a template, so the pin is built by hand: compute does not rely on its caller having checked.
    var plats = [_]pins.Platform{
        .{ .id = "linux", .token = "linux", .sha256 = fx.ABC_SHA256, .size = 3 },
        .{ .id = "bad\"", .token = "l", .sha256 = fx.ABC_SHA256, .size = 3 },
    };
    const bad = [_]pins.Pin{.{ .name = "tool", .version = "1.0.0", .url = "https://h.example/{nope}", .platforms = &plats }};
    var rep = Report.init(a);
    const lock = try resolve.compute(a, .{ .pins = &bad }, .{}, &rep);
    try t.expectEqual(@as(usize, 2), rep.errors.count());
    try t.expectEqualStrings("tool: url template does not expand for linux", rep.errors.msgs.items[0]);
    try t.expectEqual(@as(usize, 0), rep.alarms.count());
    try t.expectEqual(@as(usize, 1), lock.pins.len);
    try t.expectEqual(@as(usize, 0), lock.pins[0].files.len);
}

test "compute: a hash written in pins.toml is the lock's when the lock has none for that platform" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var plats = [_]pins.Platform{.{ .id = "linux", .token = "linux", .sha256 = fx.ABC_SHA256, .size = 3 }};
    const p = [_]pins.Pin{.{ .name = "tool", .version = "1.0.0", .url = "https://h.example/{platform}", .platforms = &plats }};
    var rep = Report.init(a);
    const lock = try resolve.compute(a, .{ .pins = &p }, .{}, &rep);
    try t.expect(rep.clean());
    try t.expectEqualStrings(fx.ABC_SHA256, lock.pins[0].files[0].sha256);
    try t.expectEqual(@as(u64, 3), lock.pins[0].files[0].size);
    // The same claim with another size, against a lock that has the file, is an alarm on the size alone.
    plats[0].size = 4;
    var rep2 = Report.init(a);
    _ = try resolve.compute(a, .{ .pins = &p }, lock, &rep2);
    try t.expectEqual(@as(usize, 1), rep2.alarms.count());
    try t.expect(std.mem.indexOf(u8, rep2.alarms.msgs.items[0], "size 4, the lock has " ++ fx.ABC_SHA256 ++ " size 3") != null);
}

test "compareToPrevious: a changed size alone is an alarm; a platform or a pin that went away is not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try prevLock(a, "1.0.0", fx.ABC_SHA256);
    var resized_files = try a.dupe(lockfmt.File, base.pins[0].files);
    resized_files[0].size = 4;
    const resized = [_]lockfmt.LockPin{.{ .name = "tool", .version = "1.0.0", .files = resized_files }};
    var rep = Report.init(a);
    resolve.compareToPrevious(base, .{ .pins = &resized }, &rep);
    try t.expectEqual(@as(usize, 1), rep.alarms.count());
    try t.expect(std.mem.indexOf(u8, rep.alarms.msgs.items[0], "was sha256 " ++ fx.ABC_SHA256 ++ " size 3, is now " ++ fx.ABC_SHA256 ++ " size 4") != null);
    // One platform gone, and then the whole pin gone: removal is a normal edit.
    const fewer = [_]lockfmt.LockPin{.{ .name = "tool", .version = "1.0.0", .files = base.pins[0].files[0..1] }};
    var rep2 = Report.init(a);
    resolve.compareToPrevious(base, .{ .pins = &fewer }, &rep2);
    resolve.compareToPrevious(base, .{}, &rep2);
    try t.expect(rep2.clean());
}

test "compareToPrevious: npm integrity or size changed alone is an alarm; a package that went away is not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = try prevNpm(a, fx.ABC_SRI512);
    var other_sri = base.npm[0];
    other_sri.sri512 = try fx.sri512(a, fx.ABD);
    var other_size = base.npm[0];
    other_size.size = 4;
    for ([_]lockfmt.Npm{ other_sri, other_size }) |changed| {
        var rep = Report.init(a);
        resolve.compareToPrevious(base, .{ .npm = &.{changed} }, &rep);
        try t.expectEqual(@as(usize, 1), rep.alarms.count());
        try t.expect(std.mem.indexOf(u8, rep.alarms.msgs.items[0], "left-pad@1.3.0: was sha256 ") != null);
    }
    var rep = Report.init(a);
    resolve.compareToPrevious(base, .{}, &rep);
    try t.expect(rep.clean());
}
