//! Support for the tests of the commit half (not a test file itself): a fake GitHub that answers from a table of
//! routes and records every request, a zip writer in the layout `upload-artifact` produces, and a "world": a
//! repository, a Dependabot pull request that bumped one package, the artifact a compute run made for it, and
//! every API answer `commit-check` asks for. A test installs the world, changes the one answer it attacks, and runs.

const std = @import("std");
const kit = @import("testkit.zig");
const api_mod = @import("autopin_api.zig");
const ctxm = @import("ctx.zig");
const gh = @import("autopin_gh.zig");
const lock_mod = @import("autopin_lock.zig");
const manifest_mod = @import("autopin_manifest.zig");
const sets_mod = @import("autopin_sets.zig");
const Diag = @import("diag.zig").Diag;
const table_mod = @import("autopin_table.zig");

pub const sri_a = "sha512-" ++ "A" ** 86 ++ "==";
pub const sri_b = "sha512-" ++ "B" ** 85 ++ "A==";
pub const sha_a = "a" ** 64;
pub const sha_b = "b" ** 64;
pub const head = "3" ** 40;
pub const base = "4" ** 40;
pub const merge_base = "5" ** 40;
pub const tree = "6" ** 40;
pub const repo = "acme/demo";
pub const branch = "dependabot/npm_and_yarn/site/left-pad-1.3.1";
pub const blob_url = "https://pipelinesghubeus1.blob.core.windows.net/artifacts/a1?sv=v1&sig=abc";

pub const Route = struct {
    method: api_mod.Method,
    key: []const u8,
    accept: ?[]const u8 = null,
    status: u16 = 200,
    body: []const u8 = "",
    location: ?[]const u8 = null,
};

pub const Logged = struct { method: api_mod.Method, key: []const u8, accept: []const u8, auth: bool, body: ?[]const u8 };

pub const Fake = struct {
    a: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    log: std.ArrayList(Logged) = .empty,
    missing: []const u8 = "",

    pub fn api(self: *Fake) api_mod.Api {
        return .{ .ctx = self, .sendFn = send };
    }

    /// The answer to `method key` (the last put wins), whatever the media type.
    pub fn put(self: *Fake, method: api_mod.Method, key: []const u8, status: u16, body: []const u8) void {
        self.routes.append(self.a, .{ .method = method, .key = key, .status = status, .body = body }) catch unreachable;
    }

    pub fn putAccept(self: *Fake, method: api_mod.Method, key: []const u8, accept: []const u8, status: u16, body: []const u8) void {
        self.routes.append(self.a, .{ .method = method, .key = key, .accept = accept, .status = status, .body = body }) catch unreachable;
    }

    pub fn putRedirect(self: *Fake, key: []const u8, location: []const u8) void {
        self.routes.append(self.a, .{ .method = .GET, .key = key, .status = 302, .location = location }) catch unreachable;
    }

    fn send(ctx: *anyopaque, a: std.mem.Allocator, req: api_mod.Request) anyerror!api_mod.Response {
        _ = a;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const key = req.url orelse req.path;
        // A replay of the command (failing streams and allocators, see testkit) must not count as a request.
        if (!kit.replaying) try self.log.append(self.a, .{ .method = req.method, .key = key, .accept = req.accept, .auth = req.auth, .body = req.body });
        var i = self.routes.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.routes.items[i];
            if (r.method != req.method or !std.mem.eql(u8, r.key, key)) continue;
            if (r.accept) |want| if (!std.mem.eql(u8, want, req.accept)) continue;
            return .{ .status = r.status, .body = r.body, .location = r.location };
        }
        self.missing = key;
        return error.NoRoute;
    }

    pub fn count(self: *const Fake, method: api_mod.Method) usize {
        var n: usize = 0;
        for (self.log.items) |l| if (l.method == method) {
            n += 1;
        };
        return n;
    }

    pub fn requested(self: *const Fake, method: api_mod.Method, key: []const u8) bool {
        for (self.log.items) |l| if (l.method == method and std.mem.eql(u8, l.key, key)) return true;
        return false;
    }

    pub fn bodyOf(self: *const Fake, method: api_mod.Method, key: []const u8) ?[]const u8 {
        for (self.log.items) |l| if (l.method == method and std.mem.eql(u8, l.key, key)) return l.body;
        return null;
    }
};

pub const Part = struct { name: []const u8, data: []const u8 };

fn put16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .little);
}
fn put32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}

/// A zip as `upload-artifact` writes it: deflate members (here one stored block each), flag bit 3, zeros in the local
/// header, a signed data descriptor after the data.
pub fn zipOf(a: std.mem.Allocator, parts: []const Part) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var cd = std.ArrayList(u8).empty;
    for (parts) |p| {
        var comp = std.ArrayList(u8).empty;
        try comp.append(a, 0x01);
        const n: u16 = @intCast(p.data.len);
        try comp.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
        try comp.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
        try comp.appendSlice(a, p.data);
        const crc = std.hash.Crc32.hash(p.data);
        const lfh = out.items.len;
        var h: [30]u8 = [_]u8{0} ** 30;
        put32(&h, 0, 0x04034b50);
        put16(&h, 4, 20);
        put16(&h, 6, 0x0008);
        put16(&h, 8, 8);
        put16(&h, 26, @intCast(p.name.len));
        try out.appendSlice(a, &h);
        try out.appendSlice(a, p.name);
        try out.appendSlice(a, comp.items);
        var d: [16]u8 = undefined;
        put32(&d, 0, 0x08074b50);
        put32(&d, 4, crc);
        put32(&d, 8, @intCast(comp.items.len));
        put32(&d, 12, @intCast(p.data.len));
        try out.appendSlice(a, &d);
        var c: [46]u8 = [_]u8{0} ** 46;
        put32(&c, 0, 0x02014b50);
        put16(&c, 4, 0x031e);
        put16(&c, 6, 20);
        put16(&c, 8, 0x0008);
        put16(&c, 10, 8);
        put32(&c, 16, crc);
        put32(&c, 20, @intCast(comp.items.len));
        put32(&c, 24, @intCast(p.data.len));
        put16(&c, 28, @intCast(p.name.len));
        put32(&c, 38, 0o100644 << 16);
        put32(&c, 42, @intCast(lfh));
        try cd.appendSlice(a, &c);
        try cd.appendSlice(a, p.name);
    }
    const cd_off = out.items.len;
    try out.appendSlice(a, cd.items);
    var e: [22]u8 = [_]u8{0} ** 22;
    put32(&e, 0, 0x06054b50);
    put16(&e, 8, @intCast(parts.len));
    put16(&e, 10, @intCast(parts.len));
    put32(&e, 12, @intCast(cd.items.len));
    put32(&e, 16, @intCast(cd_off));
    try out.appendSlice(a, &e);
    return out.items;
}

fn rowFor(a: std.mem.Allocator, name: []const u8, version: []const u8, sri: []const u8, sha: []const u8, size: u64) !table_mod.Row {
    return .{
        .key = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version }),
        .name = name,
        .version = version,
        .url = try lock_mod.canonicalUrl(a, name, version),
        .sri512 = sri,
        .sha256 = sha,
        .size = size,
    };
}

pub fn lockJson(a: std.mem.Allocator, pad_version: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"name":"demo","lockfileVersion":3,"packages":{{"":{{"name":"demo"}},
        \\"node_modules/@scope/pkg":{{"version":"2.0.0","resolved":"https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.0.tgz","integrity":"{s}"}},
        \\"node_modules/left-pad":{{"version":"{s}","resolved":"https://registry.npmjs.org/left-pad/-/left-pad-{s}.tgz","integrity":"{s}"}}{s}}}}}
    , .{ sri_b, pad_version, pad_version, sri_a, extra });
}

pub const pins_prefix = "# GENERATED by kpin. Do not edit by hand.\n\nKPIN_LOCK_VERSION = 1\n\nPINS = {}\n\n";

pub fn packageJson(a: std.mem.Allocator, pad_version: []const u8, scripts: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"demo\",\"version\":\"1.0.0\",\"scripts\":{{{s}}},\"dependencies\":{{\"left-pad\":\"{s}\"}}{s}}}", .{ scripts, pad_version, extra });
}

pub fn eventJson(a: std.mem.Allocator, attempt: i64, head_sha: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"workflow_run":{{"id":1001,"run_attempt":{d},"head_sha":"{s}","head_branch":"{s}","conclusion":"success","event":"pull_request","path":".github/workflows/autopin-compute.yml","head_repository":{{"id":42,"full_name":"{s}"}},"actor":{{"login":"dependabot[bot]"}},"triggering_actor":{{"login":"dependabot[bot]"}},"pull_requests":[{{"number":7}}]}},"repository":{{"full_name":"{s}","id":42}}}}
    , .{ attempt, head_sha, branch, repo, repo });
}

/// The repository in which one pull request bumped left-pad from 1.3.0 to 1.3.1 in `dir`.
pub const World = struct {
    a: std.mem.Allocator,
    fake: *Fake,
    kind: sets_mod.Kind,
    dir: []const u8,
    pj_base: []const u8,
    pj_head: []const u8,
    lock_head: []const u8,
    table_head: []const u8,
    table_new: []const u8,
    table_path: []const u8,
    zip_bytes: []const u8,
    manifest_text: []const u8,

    pub fn init(a: std.mem.Allocator, fake: *Fake, kind: sets_mod.Kind, dir: []const u8, head_extra: []const u8) !World {
        const old_rows = [_]table_mod.Row{
            try rowFor(a, "@scope/pkg", "2.0.0", sri_b, sha_b, 22),
            try rowFor(a, "left-pad", "1.3.0", sri_a, sha_a, 11),
        };
        const new_rows = [_]table_mod.Row{
            try rowFor(a, "@scope/pkg", "2.0.0", sri_b, sha_b, 22),
            try rowFor(a, "left-pad", "1.3.1", sri_a, sha_b, 12),
        };
        const scripts = "\"test\":\"jest\"";
        const pj_base = try packageJson(a, "1.3.0", scripts, "");
        const pj_head = try packageJson(a, "1.3.1", scripts, head_extra);
        const lock_old = try lockJson(a, "1.3.0", "");
        const lock_head = try lockJson(a, "1.3.1", "");
        var diag = Diag.init(a);
        const table_head: []const u8 = switch (kind) {
            .buildrules_lock => (try table_mod.freshBuildrules(a, pj_base, lock_old, &old_rows, &diag)).?,
            .pins_lock => try table_mod.freshPins(a, pins_prefix, &old_rows),
        };
        const table_new: []const u8 = switch (kind) {
            .buildrules_lock => (try table_mod.freshBuildrules(a, pj_head, lock_head, &new_rows, &diag)).?,
            .pins_lock => try table_mod.freshPins(a, pins_prefix, &new_rows),
        };
        const set = sets_mod.Set{ .dir = dir, .kind = kind };
        const table_path = try sets_mod.Sets.tablePath(a, set);
        const digest = try ctxm.sha256Hex(a, table_new);
        const files = [_]manifest_mod.File{.{ .path = table_path, .sha256 = digest }};
        const manifest_text = try manifest_mod.render(a, .{ .pr = 7, .head_sha = head, .base_sha = base, .files = &files });
        const zip_bytes = try zipOf(a, &.{ .{ .name = "manifest.json", .data = manifest_text }, .{ .name = table_path, .data = table_new } });
        return .{ .a = a, .fake = fake, .kind = kind, .dir = dir, .pj_base = pj_base, .pj_head = pj_head, .lock_head = lock_head, .table_head = table_head, .table_new = table_new, .table_path = table_path, .zip_bytes = zip_bytes, .manifest_text = manifest_text };
    }

    pub fn file(self: *World, path: []const u8, ref: []const u8, bytes: []const u8) !void {
        const key = try std.fmt.allocPrint(self.a, "repos/{s}/contents/{s}?ref={s}", .{ repo, path, ref });
        const sha = try gh.blobSha1(self.a, bytes);
        const meta = try std.fmt.allocPrint(self.a, "{{\"type\":\"file\",\"sha\":\"{s}\",\"size\":{d},\"content\":\"\",\"encoding\":\"none\"}}", .{ sha, bytes.len });
        self.fake.putAccept(.GET, key, api_mod.json_accept, 200, meta);
        self.fake.putAccept(.GET, key, api_mod.raw_accept, 200, bytes);
    }

    pub fn pathOf(self: *World, name: []const u8) ![]u8 {
        return sets_mod.Sets.path(self.a, .{ .dir = self.dir, .kind = self.kind }, name);
    }

    /// Every route a good run asks for.
    pub fn install(self: *World) !void {
        const a = self.a;
        const f = self.fake;
        try self.file(try self.pathOf("package.json"), head, self.pj_head);
        try self.file(try self.pathOf("package.json"), merge_base, self.pj_base);
        try self.file(try self.pathOf("package-lock.json"), head, self.lock_head);
        try self.file(self.table_path, head, self.table_head);
        try self.file(self.table_path, merge_base, self.table_head);
        f.put(.GET, "repos/" ++ repo, 200, "{\"id\":42,\"default_branch\":\"main\"}");
        f.put(.GET, "repos/" ++ repo ++ "/actions/runs/1001/artifacts?name=autopin-1001-1&per_page=100", 200, "{\"total_count\":1,\"artifacts\":[{\"id\":555,\"name\":\"autopin-1001-1\",\"expired\":false}]}");
        f.putRedirect("repos/" ++ repo ++ "/actions/artifacts/555/zip", blob_url);
        f.put(.GET, blob_url, 200, self.zip_bytes);
        f.put(.GET, "repos/" ++ repo ++ "/pulls/7", 200, try prJson(a, "open", "dependabot[bot]", repo, "main", head));
        f.put(.GET, "repos/" ++ repo ++ "/pulls/7/commits?per_page=100&page=1", 200, "[{\"author\":{\"login\":\"dependabot[bot]\"}}]");
        const names = try std.fmt.allocPrint(a, "[{{\"filename\":\"{s}\"}},{{\"filename\":\"{s}\"}},{{\"filename\":\"{s}\"}}]", .{ try self.pathOf("package.json"), try self.pathOf("package-lock.json"), self.table_path });
        f.put(.GET, "repos/" ++ repo ++ "/pulls/7/files?per_page=100&page=1", 200, names);
        f.put(.GET, "repos/" ++ repo ++ "/compare/" ++ base ++ "..." ++ head, 200, "{\"merge_base_commit\":{\"sha\":\"" ++ merge_base ++ "\"}}");
    }
};

pub fn prJson(a: std.mem.Allocator, state: []const u8, user: []const u8, head_repo: []const u8, base_ref: []const u8, head_sha: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"user\":{{\"login\":\"{s}\"}},\"head\":{{\"sha\":\"{s}\",\"ref\":\"{s}\",\"repo\":{{\"full_name\":\"{s}\"}}}},\"base\":{{\"ref\":\"{s}\",\"sha\":\"{s}\"}}}}", .{ state, user, head_sha, branch, head_repo, base_ref, base });
}
