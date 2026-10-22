//! publish_unpack.zig against a recorder in place of `buck2` and `gh`: what a dry run touches (nothing on GitHub), the order of an --apply, that an asset is never replaced
//! or deleted and no replacing flag is ever passed, and that a program which is not the pinned one stops everything before the first write.
const std = @import("std");
const pub_ = @import("publish_unpack.zig");
const pins = @import("bootstrap_pins");
const t = std.testing;
const a = t.allocator;

const Fake = struct {
    root: []const u8,
    store: []const u8,
    calls: std.ArrayList([]u8) = .empty,
    release_exists: bool = false,
    assets: std.ArrayList([]u8) = .empty,
    build_code: u8 = 0,
    create_code: u8 = 0,
    upload_code: u8 = 0,
    download_code: u8 = 0,
    corrupt_downloads: bool = false,
    skip_download_file: bool = false,
    relative_paths: bool = false,
    omit_path_of: ?[]const u8 = null,
    head: []const u8 = "0123456789abcdef0123456789abcdef01234567\n",
    head_code: u8 = 0,
    status: []const u8 = "",

    fn deinit(self: *Fake) void {
        for (self.calls.items) |c| a.free(c);
        self.calls.deinit(a);
        for (self.assets.items) |c| a.free(c);
        self.assets.deinit(a);
    }

    fn runner(self: *Fake) pub_.Runner {
        return .{ .ctx = self, .runFn = call };
    }

    fn call(ctx: *anyopaque, alloc: std.mem.Allocator, argv: []const []const u8, _: []const u8) anyerror!pub_.Ran {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.calls.append(a, try std.mem.join(a, " ", argv));
        const prog = argv[0];
        if (std.mem.eql(u8, prog, "fake-git")) {
            if (std.mem.eql(u8, argv[3], "rev-parse")) return .{ .code = self.head_code, .out = try alloc.dupe(u8, self.head) };
            return .{ .code = 0, .out = try alloc.dupe(u8, self.status) };
        }
        if (std.mem.eql(u8, prog, "fake-buck2")) {
            if (self.build_code != 0) return .{ .code = self.build_code, .out = try alloc.dupe(u8, "") };
            var out = std.ArrayList(u8).empty;
            for (pins.hosts) |h| {
                if (self.omit_path_of) |o| if (std.mem.eql(u8, o, h)) continue;
                const name = try std.fmt.allocPrint(a, "unpack_{s}", .{h});
                defer a.free(name);
                for (@constCast(name)) |*c| {
                    if (c.* == '-') c.* = '_';
                }
                const line = if (self.relative_paths)
                    try std.fmt.allocPrint(a, "buildrules//tools/bootstrap:{s} built/{s}\n", .{ name, name })
                else
                    try std.fmt.allocPrint(a, "buildrules//tools/bootstrap:{s} {s}/built/{s}\n", .{ name, self.root, name });
                defer a.free(line);
                try out.appendSlice(alloc, line);
            }
            return .{ .code = 0, .out = try out.toOwnedSlice(alloc) };
        }
        // gh
        if (std.mem.eql(u8, argv[1], "api")) {
            if (!self.release_exists) return .{ .code = 1, .out = try alloc.dupe(u8, "") };
            var out = std.ArrayList(u8).empty;
            for (self.assets.items) |n| {
                try out.appendSlice(alloc, n);
                try out.append(alloc, '\n');
            }
            return .{ .code = 0, .out = try out.toOwnedSlice(alloc) };
        }
        if (std.mem.eql(u8, argv[2], "create")) {
            if (self.create_code == 0) self.release_exists = true;
            return .{ .code = self.create_code, .out = try alloc.dupe(u8, "") };
        }
        if (std.mem.eql(u8, argv[2], "upload")) {
            if (self.upload_code != 0) return .{ .code = self.upload_code, .out = try alloc.dupe(u8, "") };
            const src = argv[4];
            const name = std.fs.path.basename(src);
            try self.assets.append(a, try a.dupe(u8, name));
            const dest = try std.fs.path.join(a, &.{ self.store, name });
            defer a.free(dest);
            try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
            return .{ .code = 0, .out = try alloc.dupe(u8, "") };
        }
        if (std.mem.eql(u8, argv[2], "download")) {
            if (self.download_code != 0) return .{ .code = self.download_code, .out = try alloc.dupe(u8, "") };
            // gh release download TAG --repo R --pattern NAME --dir DIR
            const name = argv[7];
            const dir = argv[9];
            if (self.skip_download_file) return .{ .code = 0, .out = try alloc.dupe(u8, "") };
            const src = try std.fs.path.join(a, &.{ self.store, name });
            defer a.free(src);
            const dest = try std.fs.path.join(a, &.{ dir, name });
            defer a.free(dest);
            try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
            if (self.corrupt_downloads) {
                var f = try std.fs.cwd().openFile(dest, .{ .mode = .read_write });
                defer f.close();
                try f.writeAll("X");
            }
            return .{ .code = 0, .out = try alloc.dupe(u8, "") };
        }
        return error.UnexpectedCall;
    }

    fn called(self: *const Fake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }
};

const Lines = struct {
    list: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Lines) void {
        for (self.list.items) |l| a.free(l);
        self.list.deinit(a);
    }

    fn say(self: *Lines) pub_.Say {
        return .{ .ctx = self, .sayFn = push };
    }

    fn push(ctx: *anyopaque, line: []const u8) void {
        const self: *Lines = @ptrCast(@alignCast(ctx));
        self.list.append(a, a.dupe(u8, line) catch return) catch return;
    }

    fn has(self: *const Lines, needle: []const u8) bool {
        for (self.list.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) return true;
        }
        return false;
    }
};

/// A repository root with the three fake programs and a table that pins them (or pins `pin_wrong` hosts wrongly), a store for uploaded assets, and a work directory.
const World = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    store: []u8,
    work: []u8,

    fn init(wrong_host: ?[]const u8) !World {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.makePath("built");
        try tmp.dir.makePath("rules/pins");
        try tmp.dir.makePath("store");
        try tmp.dir.makePath("work");
        var table = std.ArrayList(u8).empty;
        defer table.deinit(a);
        try table.appendSlice(a, "UNPACK_TAG = \"unpack-4\"\n\nUNPACK_PINS = {\n");
        for (pins.hosts, 0..) |h, i| {
            const name = try std.fmt.allocPrint(a, "unpack_{s}", .{h});
            defer a.free(name);
            for (@constCast(name)) |*c| {
                if (c.* == '-') c.* = '_';
            }
            const content = try std.fmt.allocPrint(a, "program for {s}, number {d}", .{ h, i });
            defer a.free(content);
            const path = try std.fmt.allocPrint(a, "built/{s}", .{name});
            defer a.free(path);
            try tmp.dir.writeFile(.{ .sub_path = path, .data = content });
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(content, &d, .{});
            var hex = std.fmt.bytesToHex(d, .lower);
            if (wrong_host) |w| if (std.mem.eql(u8, w, h)) {
                hex[0] = if (hex[0] == '0') '1' else '0';
            };
            const row = try std.fmt.allocPrint(a, "    \"{s}\": {{\n        \"url\": \"{s}unpack-4/unpack-{s}\",\n        \"sha256\": \"{s}\",\n        \"size\": {d},\n    }},\n", .{ h, pins.base, h, &hex, content.len });
            defer a.free(row);
            try table.appendSlice(a, row);
        }
        try table.appendSlice(a, "}\n");
        try tmp.dir.writeFile(.{ .sub_path = "rules/pins/bootstrap.bzl", .data = table.items });
        const root = try tmp.dir.realpathAlloc(a, ".");
        return .{
            .tmp = tmp,
            .root = root,
            .store = try std.fs.path.join(a, &.{ root, "store" }),
            .work = try std.fs.path.join(a, &.{ root, "work" }),
        };
    }

    fn deinit(self: *World) void {
        a.free(self.root);
        a.free(self.store);
        a.free(self.work);
        self.tmp.cleanup();
    }

    fn fake(self: *World) Fake {
        return .{ .root = self.root, .store = self.store };
    }

    fn options(self: *World, apply: bool) pub_.Options {
        return .{ .apply = apply, .root = self.root, .buck2 = "fake-buck2", .gh = "fake-gh", .git = "fake-git", .work = if (apply) self.work else null };
    }
};

/// No call replaced or deleted anything.
fn expectNoReplacing(f: *const Fake) !void {
    for (f.calls.items) |c| {
        for ([_][]const u8{ "--clobber", "--force", "-f ", "delete", "--cleanup-tag" }) |bad| {
            if (std.mem.indexOf(u8, c, bad) != null) {
                std.debug.print("a call replaces or deletes: {s}\n", .{c});
                return error.ReplacingCall;
            }
        }
    }
}

test "a dry run builds, checks and reads the release, and writes nothing on GitHub" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(false), f.runner(), out.say()));
    try t.expectEqual(@as(usize, 1), f.called("fake-buck2 build --show-full-output"));
    try t.expectEqual(@as(usize, 1), f.called("fake-gh api repos/" ++ pub_.repo ++ "/releases/tags/unpack-4"));
    try t.expectEqual(@as(usize, 0), f.called("release create"));
    try t.expectEqual(@as(usize, 0), f.called("release upload"));
    try t.expectEqual(@as(usize, 0), f.called("release download"));
    try t.expect(out.has("dry run"));
    try t.expect(out.has("could not be read"));
    try t.expect(out.has("create the release"));
    try t.expect(out.has("unpack-4"));
    try expectNoReplacing(&f);
}

test "a dry run reads an existing release, and warns of an asset no pin names without deleting it" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    f.release_exists = true;
    try f.assets.append(a, try a.dupe(u8, "unpack-linux-x86_64"));
    try f.assets.append(a, try a.dupe(u8, "stray.bin"));
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(false), f.runner(), out.say()));
    try t.expect(out.has("it exists"));
    try t.expect(out.has("WARNING"));
    try t.expect(out.has("gh release delete-asset unpack-4 'stray.bin' --repo " ++ pub_.repo));
    try t.expectEqual(@as(usize, 0), f.called("delete-asset"));
    try t.expect(!out.has("create the release"));
    try expectNoReplacing(&f);
}

test "an empty release is read as holding no assets" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    f.release_exists = true;
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(false), f.runner(), out.say()));
    try t.expect(out.has("its assets: none"));
}

test "--apply creates the release, uploads the three assets, downloads and verifies each" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(true), f.runner(), out.say()));
    try t.expectEqual(@as(usize, 1), f.called("release create unpack-4 --repo " ++ pub_.repo ++ " --target 0123456789abcdef0123456789abcdef01234567 --latest=false"));
    try t.expectEqual(@as(usize, 3), f.called("release upload unpack-4"));
    try t.expectEqual(@as(usize, 3), f.called("release download unpack-4"));
    try t.expect(out.has("unpack-linux-x86_64 matches the pin"));
    try t.expect(out.has("unpack-linux-aarch64 matches the pin"));
    try t.expect(out.has("unpack-macos-aarch64 matches the pin"));
    try t.expect(out.has("done:"));
    try expectNoReplacing(&f);
    // the order: build, read, create, upload, download
    var seen_create = false;
    var seen_download = false;
    for (f.calls.items) |c| {
        if (std.mem.indexOf(u8, c, "release create") != null) seen_create = true;
        if (std.mem.indexOf(u8, c, "release upload") != null) try t.expect(seen_create and !seen_download);
        if (std.mem.indexOf(u8, c, "release download") != null) seen_download = true;
    }
    // each asset is uploaded under its own name, from a copy named for it
    try t.expect(f.called("work/unpack-linux-x86_64") >= 1);
}

test "--apply with the release and one asset already there uploads the other two and only verifies the one" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    f.release_exists = true;
    // the asset that is there must be the real bytes: put them in the store as an earlier upload would have
    try w.tmp.dir.copyFile("built/unpack_linux_aarch64", w.tmp.dir, "store/unpack-linux-aarch64", .{});
    try f.assets.append(a, try a.dupe(u8, "unpack-linux-aarch64"));
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(true), f.runner(), out.say()));
    try t.expectEqual(@as(usize, 0), f.called("release create"));
    try t.expectEqual(@as(usize, 2), f.called("release upload"));
    try t.expect(out.has("unpack-linux-aarch64 is already there; it is not replaced"));
    try t.expectEqual(@as(usize, 3), f.called("release download"));
    try expectNoReplacing(&f);
}

test "an asset that is there with other bytes than the pin fails the verification and is not replaced" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    f.release_exists = true;
    try w.tmp.dir.writeFile(.{ .sub_path = "store/unpack-macos-aarch64", .data = "someone else's bytes" });
    try f.assets.append(a, try a.dupe(u8, "unpack-macos-aarch64"));
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 1), try pub_.publish(a, w.options(true), f.runner(), out.say()));
    try t.expect(out.has("does not match the pin"));
    try t.expectEqual(@as(usize, 2), f.called("release upload"));
    try expectNoReplacing(&f);
}

test "programs that are not the pinned ones stop everything before the first write" {
    for (pins.hosts) |h| {
        var w = try World.init(h);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 1), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expectEqual(@as(usize, 0), f.called("fake-gh"));
        try t.expect(out.has("this tree builds unpack"));
        try t.expect(out.has("Nothing was uploaded"));
    }
}

test "problems with the repository or the tools are exit 2 and change nothing" {
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.build_code = 1;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("the build failed"));
        try t.expectEqual(@as(usize, 0), f.called("fake-gh"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.omit_path_of = "macos-aarch64";
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
        try t.expect(out.has("printed no path"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        try w.tmp.dir.deleteFile("built/unpack_linux_aarch64");
        var f = w.fake();
        defer f.deinit();
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
        try t.expect(out.has("cannot read"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        try w.tmp.dir.deleteFile("rules/pins/bootstrap.bzl");
        var f = w.fake();
        defer f.deinit();
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
        try t.expect(out.has("cannot read"));
        try t.expectEqual(@as(usize, 0), f.calls.items.len);
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        try w.tmp.dir.writeFile(.{ .sub_path = "rules/pins/bootstrap.bzl", .data = "UNPACK_PINS = {}\n" });
        var f = w.fake();
        defer f.deinit();
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
        try t.expect(out.has("has no UNPACK_TAG"));
    }
}

test "paths the build prints relative to the root are read from there" {
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    f.relative_paths = true;
    var out = Lines{};
    defer out.deinit();
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(false), f.runner(), out.say()));
}

test "failures of gh while applying are exit 2 (a write failed) or 1 (an asset does not verify)" {
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.create_code = 1;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("gh release create failed"));
        try t.expectEqual(@as(usize, 0), f.called("release upload"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.upload_code = 1;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("upload of unpack-linux-x86_64 failed"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.download_code = 1;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 1), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("cannot be downloaded"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.skip_download_file = true;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 1), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("left no file"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.corrupt_downloads = true;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 1), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("does not match the pin"));
    }
    {
        // a work directory that does not exist
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        var o = w.options(true);
        o.work = "/nonexistent/work/dir";
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, o, f.runner(), out.say()));
        try t.expect(out.has("cannot copy"));
    }
}

test "parse: the options, and apply needs a work directory" {
    var diag: []const u8 = "";
    const o = try pub_.parse(&.{ "--apply", "--work", "w", "--root", "r", "--buck2", "b", "--gh", "g", "--git", "gi" }, &diag);
    try t.expect(o.apply);
    try t.expectEqualStrings("w", o.work.?);
    try t.expectEqualStrings("r", o.root);
    try t.expectEqualStrings("b", o.buck2);
    try t.expectEqualStrings("g", o.gh);
    try t.expectEqualStrings("gi", o.git);
    const d = try pub_.parse(&.{}, &diag);
    try t.expect(!d.apply);
    try t.expectError(error.Usage, pub_.parse(&.{"--apply"}, &diag));
    try t.expect(std.mem.indexOf(u8, diag, "--apply needs --work") != null);
    try t.expectError(error.Usage, pub_.parse(&.{"--root"}, &diag));
    try t.expectEqualStrings("an option has no value", diag);
    try t.expectError(error.Usage, pub_.parse(&.{ "--force", "x" }, &diag));
    try t.expect(std.mem.indexOf(u8, diag, "unknown argument") != null);
    // the flags that replace or force are not options at all
    try t.expectError(error.Usage, pub_.parse(&.{ "--clobber", "x" }, &diag));
}

test "--buck2-config reaches the build as -c KEY=VALUE, before the targets, and is only a KEY=VALUE" {
    var diag: []const u8 = "";
    const o = try pub_.parse(&.{ "--buck2-config", "buildrules_re.mode=local" }, &diag);
    try t.expectEqualStrings("buildrules_re.mode=local", o.buck2_config.?);
    try t.expect((try pub_.parse(&.{}, &diag)).buck2_config == null);
    try t.expectError(error.Usage, pub_.parse(&.{ "--buck2-config", "local" }, &diag));
    try t.expect(std.mem.indexOf(u8, diag, "--buck2-config needs KEY=VALUE") != null);
    // an empty key, an empty value, or nothing at all is refused too
    for ([_][]const u8{ "=local", "buildrules_re.mode=", "=", "" }) |bad| {
        try t.expectError(error.Usage, pub_.parse(&.{ "--buck2-config", bad }, &diag));
    }
    var w = try World.init(null);
    defer w.deinit();
    var f = w.fake();
    defer f.deinit();
    var out = Lines{};
    defer out.deinit();
    var opts = w.options(false);
    opts.buck2_config = "buildrules_re.mode=local";
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, opts, f.runner(), out.say()));
    try t.expectEqual(@as(usize, 1), f.called("fake-buck2 build -c buildrules_re.mode=local --show-full-output -- //tools/bootstrap:unpack_"));
}

test "the token variables go to the gh program alone, not to git or buck2" {
    var env = std.process.EnvMap.init(a);
    defer env.deinit();
    try env.put("GH_TOKEN", "token-one");
    try env.put("GITHUB_TOKEN", "token-two");
    try env.put("GH_ENTERPRISE_TOKEN", "token-three");
    try env.put("GITHUB_ENTERPRISE_TOKEN", "token-four");
    try env.put("KEEP_ME", "kept");
    // the environment function: gh keeps all of it, any other program loses the four and keeps the rest
    {
        var for_gh = try pub_.childEnv(a, &env, "gh", "gh");
        defer for_gh.deinit();
        try t.expectEqual(@as(u32, 5), for_gh.count());
    }
    for ([_][]const u8{ "git", "buck2", "/work/buck2", "ghx", "" }) |prog| {
        var other = try pub_.childEnv(a, &env, prog, "gh");
        defer other.deinit();
        try t.expectEqual(@as(u32, 1), other.count());
        try t.expectEqualStrings("kept", other.get("KEEP_ME").?);
    }
    try t.expectEqual(@as(u32, 5), env.count());
    // through the runner, with a real child that prints its environment
    {
        var real = pub_.RealRunner{ .gh = "/usr/bin/env", .env = &env };
        const r = try real.runner().run(a, &.{"/usr/bin/env"}, "/");
        defer a.free(r.out);
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(std.mem.indexOf(u8, r.out, "GH_TOKEN=token-one") != null);
        try t.expect(std.mem.indexOf(u8, r.out, "GITHUB_TOKEN=token-two") != null);
    }
    {
        var real = pub_.RealRunner{ .gh = "gh", .env = &env };
        const r = try real.runner().run(a, &.{"/usr/bin/env"}, "/");
        defer a.free(r.out);
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(std.mem.indexOf(u8, r.out, "KEEP_ME=kept") != null);
        try t.expect(std.mem.indexOf(u8, r.out, "token-") == null);
    }
}

test "the release points at the commit the programs were built from, and a tree with changes is refused" {
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.head = "fedcba9876543210fedcba9876543210fedcba98\n";
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expectEqual(@as(usize, 1), f.called("--target fedcba9876543210fedcba9876543210fedcba98 --latest=false"));
        try t.expectEqual(@as(usize, 0), f.called("--target main"));
        try t.expect(out.has("0. the commit: fedcba9876543210fedcba9876543210fedcba98"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.status = " M tools/bootstrap/src/tar.zig\n";
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(true), f.runner(), out.say()));
        try t.expect(out.has("changes that are not committed"));
        try t.expectEqual(@as(usize, 0), f.called("fake-gh"));
        try t.expectEqual(@as(usize, 0), f.called("fake-buck2"));
        // a dry run only warns
        var f2 = w.fake();
        defer f2.deinit();
        f2.status = " M x\n";
        var out2 = Lines{};
        defer out2.deinit();
        try t.expectEqual(@as(u8, 0), try pub_.publish(a, w.options(false), f2.runner(), out2.say()));
        try t.expect(out2.has("WARNING: the tree has changes"));
    }
    for ([_][]const u8{ "", "not a sha\n", "ABCDEF9876543210fedcba9876543210fedcba98\n" }) |bad| {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.head = bad;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
        try t.expect(out.has("cannot read the commit"));
    }
    {
        var w = try World.init(null);
        defer w.deinit();
        var f = w.fake();
        defer f.deinit();
        f.head_code = 128;
        var out = Lines{};
        defer out.deinit();
        try t.expectEqual(@as(u8, 2), try pub_.publish(a, w.options(false), f.runner(), out.say()));
    }
}

test "each run downloads into a directory of its own, so a second run meets no file of the first" {
    var w = try World.init(null);
    defer w.deinit();
    var first = w.fake();
    defer first.deinit();
    var out = Lines{};
    defer out.deinit();
    var o = w.options(true);
    o.run_id = "100";
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, o, first.runner(), out.say()));
    // the second run finds the release and the assets, and downloads again: the first run's files are still there
    var second = w.fake();
    defer second.deinit();
    second.release_exists = true;
    for (first.assets.items) |n| try second.assets.append(a, try a.dupe(u8, n));
    o.run_id = "200";
    try t.expectEqual(@as(u8, 0), try pub_.publish(a, o, second.runner(), out.say()));
    try w.tmp.dir.access("work/verify-100/unpack-linux-x86_64/unpack-linux-x86_64", .{});
    try w.tmp.dir.access("work/verify-200/unpack-linux-x86_64/unpack-linux-x86_64", .{});
    try t.expectEqual(@as(usize, 0), second.called("release upload"));
    try t.expectEqual(@as(usize, 3), second.called("work/verify-200"));
}
