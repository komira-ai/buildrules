//! The pure parts of the fetch tool: the integrity string, the host policy, and the one place bytes
//! are published. No socket is opened here, so the unit tests need none.
const std = @import("std");

const Sha512 = std.crypto.hash.sha2.Sha512;
pub const prefix = "sha512-";

pub const Error = error{ BadSri, BadUrl };

/// The 64 digest bytes of `sha512-<base64>`.
pub fn parseSri(sri: []const u8) Error![64]u8 {
    if (!std.mem.startsWith(u8, sri, prefix)) return error.BadSri;
    const dec = std.base64.standard.Decoder;
    const b64 = sri[prefix.len..];
    const n = dec.calcSizeForSlice(b64) catch return error.BadSri;
    if (n != 64) return error.BadSri;
    var out: [64]u8 = undefined;
    dec.decode(&out, b64) catch return error.BadSri;
    return out;
}

/// `sha512-<base64>` of 64 digest bytes.
pub fn sriOf(digest: [64]u8) [prefix.len + 88]u8 {
    var out: [prefix.len + 88]u8 = undefined;
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len..], &digest);
    return out;
}

/// The authority (`host[:port]`) of an http(s) URL. A `user@` is refused: it is how a URL names one host and connects to another.
pub fn authorityOf(url: []const u8) Error![]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return error.BadUrl;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return error.BadUrl;
    return authority;
}

/// Whether the URL's host (port ignored) is one of `allow`, exactly.
pub fn hostAllowed(url: []const u8, allow: []const []const u8) bool {
    const authority = authorityOf(url) catch return false;
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |c| authority[0..c] else authority;
    for (allow) |h| {
        if (std.ascii.eqlIgnoreCase(h, host)) return true;
    }
    return false;
}

/// `loc` (a Location header) against the URL it answered: absolute as is, `/path` on the same origin.
pub fn resolveRedirect(a: std.mem.Allocator, url: []const u8, loc: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, loc, "https://") or std.mem.startsWith(u8, loc, "http://")) return a.dupe(u8, loc);
    if (loc.len > 0 and loc[0] == '/') {
        const authority = try authorityOf(url);
        const scheme_len: usize = if (std.mem.startsWith(u8, url, "https://")) "https://".len else "http://".len;
        return std.fmt.allocPrint(a, "{s}{s}", .{ url[0 .. scheme_len + authority.len], loc });
    }
    return error.BadUrl;
}

pub const Published = enum { published, mismatch };

/// Writes `bytes` to `out_path` (in `dir`) if and only if their sha512 is `want`. The bytes go to `<out>.part` and are renamed
/// into place after the digest has matched, so a wrong byte never leaves a file. On a mismatch `got` holds what was computed.
pub fn publish(dir: std.fs.Dir, out_path: []const u8, bytes: []const u8, want: [64]u8, got: *[64]u8) !Published {
    Sha512.hash(bytes, got, .{});
    if (!std.mem.eql(u8, got, &want)) return .mismatch;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const part = std.fmt.bufPrint(&buf, "{s}.part", .{out_path}) catch return error.NameTooLong;
    errdefer dir.deleteFile(part) catch {};
    try dir.writeFile(.{ .sub_path = part, .data = bytes });
    try dir.rename(part, out_path);
    return .published;
}

/// TEST SEAM (`--allow-data`): the bytes of a `data:<mediatype>;base64,<payload>` URL, standing in for a network read, so that the
/// action's shape (no input files, key = tool + url + sri + out) can be exercised on a worker that has no network.
pub fn dataPayload(a: std.mem.Allocator, url: []const u8) ![]u8 {
    const head = "data:";
    if (!std.mem.startsWith(u8, url, head)) return error.BadUrl;
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return error.BadUrl;
    if (!std.mem.endsWith(u8, url[0..comma], ";base64")) return error.BadUrl;
    const b64 = url[comma + 1 ..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return error.BadUrl;
    const out = try a.alloc(u8, n);
    errdefer a.free(out);
    dec.decode(out, b64) catch return error.BadUrl;
    return out;
}
