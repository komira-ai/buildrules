//! buildrules-pins.toml: the Rust versions a repository pins itself, beyond rules/rust/pins.bzl.
//!
//!     [rust."1.86.0"]
//!     [rust."1.86.0".rustc]
//!     sha256 = "<64 lower-case hex>"
//!     size = 123456789                    # bytes of rustc-1.86.0-x86_64-unknown-linux-gnu.tar.gz
//!     [rust."1.86.0".rust-std]            # and the same for .cargo and .clippy
//!
//! Only these keys, only this shape: a table header per version and per component, `key = value` lines, `#` comments.
//! `render` turns the file into toolchains/rust_pins.bzl (pure data, read by `rust_toolchains(extra = ...)` and by the generator).
//! The tarballs are fetched from the versioned URLs (https://static.rust-lang.org/dist/rustc-<version>-x86_64-unknown-linux-gnu.tar.gz and the
//! same for the others), which carry no date. Hashes are of the `.tar.gz` variants of rustc, rust-std, cargo and clippy-preview; the sizes are the files' lengths. A pin is a review item, which
//! is why it is copied into a committed file and not read at build time.

const std = @import("std");
const valid = @import("valid.zig");
const toolchain = @import("toolchain.zig");
const Diag = @import("diag.zig").Diag;

pub const components = [_][]const u8{ "rustc", "rust-std", "cargo", "clippy" };

const Comp = struct { sha256: ?[]const u8 = null, size: ?u64 = null };
const Row = struct {
    version: []const u8,
    comp: [components.len]Comp = [_]Comp{.{}} ** components.len,
};

fn compIndex(name: []const u8) ?usize {
    for (components, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
    return null;
}

fn unquote(s: []const u8) ?[]const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return null;
    const in = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, in, '"') != null or std.mem.indexOfScalar(u8, in, '\\') != null) return null;
    return in;
}

/// The text without a trailing comment (a `#` outside quotes) and surrounding blanks.
fn bare(line: []const u8) []const u8 {
    var in_q = false;
    var end = line.len;
    for (line, 0..) |c, i| {
        if (c == '"') in_q = !in_q;
        if (c == '#' and !in_q) {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, line[0..end], " \t\r");
}

/// toolchains/rust_pins.bzl for `text`; every problem goes into `diag`. Versions come out sorted, so the file is deterministic.
pub fn render(a: std.mem.Allocator, text: []const u8, diag: *Diag) error{Invalid}![]const u8 {
    const before = diag.count();
    var rows = std.ArrayList(Row).empty;
    var cur_row: ?usize = null;
    var cur_comp: ?usize = null;
    // Inside a [mopm."V"] table, which mopm_pins.zig reads.
    var in_mopm = false;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = bare(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            cur_row = null;
            cur_comp = null;
            in_mopm = std.mem.startsWith(u8, line, "[mopm.\"");
            if (in_mopm) continue;
            if (line[line.len - 1] != ']') {
                diag.add("buildrules-pins.toml:{d}: unterminated table header", .{line_no});
                continue;
            }
            const inner = line[1 .. line.len - 1];
            // rust."V"  or  rust."V".component
            const pre = "rust.\"";
            if (!std.mem.startsWith(u8, inner, pre)) {
                diag.add("buildrules-pins.toml:{d}: unknown table [{s}] (only [rust.\"VERSION\"] and [rust.\"VERSION\".COMPONENT])", .{ line_no, inner });
                continue;
            }
            const q = std.mem.indexOfScalarPos(u8, inner, pre.len, '"') orelse {
                diag.add("buildrules-pins.toml:{d}: the version in [{s}] is not quoted", .{ line_no, inner });
                continue;
            };
            const ver = inner[pre.len..q];
            if (!toolchain.isExactRelease(ver)) {
                diag.add("buildrules-pins.toml:{d}: \"{s}\" is not an exact release N.N.N", .{ line_no, ver });
                continue;
            }
            var idx: ?usize = null;
            for (rows.items, 0..) |r, i| {
                if (std.mem.eql(u8, r.version, ver)) idx = i;
            }
            const rest = inner[q + 1 ..];
            if (rest.len == 0) {
                if (idx != null) {
                    diag.add("buildrules-pins.toml:{d}: [rust.\"{s}\"] appears twice", .{ line_no, ver });
                    continue;
                }
                rows.append(a, .{ .version = ver }) catch return error.Invalid;
                cur_row = rows.items.len - 1;
            } else if (rest[0] == '.') {
                const ci = compIndex(rest[1..]) orelse {
                    diag.add("buildrules-pins.toml:{d}: unknown component \"{s}\" (rustc, rust-std, cargo, clippy)", .{ line_no, rest[1..] });
                    continue;
                };
                if (idx == null) {
                    diag.add("buildrules-pins.toml:{d}: [{s}] comes before [rust.\"{s}\"]", .{ line_no, inner, ver });
                    continue;
                }
                cur_row = idx;
                cur_comp = ci;
            } else {
                diag.add("buildrules-pins.toml:{d}: cannot read the header [{s}]", .{ line_no, inner });
            }
            continue;
        }
        if (in_mopm) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.add("buildrules-pins.toml:{d}: not `key = value`: {s}", .{ line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const ri = cur_row orelse {
            diag.add("buildrules-pins.toml:{d}: `{s}` is outside any [rust.\"VERSION\"] table", .{ line_no, key });
            continue;
        };
        if (cur_comp) |ci| {
            if (std.mem.eql(u8, key, "sha256")) {
                const v = unquote(val) orelse {
                    diag.add("buildrules-pins.toml:{d}: sha256 must be a quoted string", .{line_no});
                    continue;
                };
                if (!valid.isSha256(v)) diag.add("buildrules-pins.toml:{d}: sha256 is not 64 lower-case hex digits", .{line_no});
                rows.items[ri].comp[ci].sha256 = v;
            } else if (std.mem.eql(u8, key, "size")) {
                const n = std.fmt.parseInt(u64, val, 10) catch 0;
                if (n == 0) diag.add("buildrules-pins.toml:{d}: size must be the file's length in bytes (a positive integer)", .{line_no});
                rows.items[ri].comp[ci].size = n;
            } else {
                diag.add("buildrules-pins.toml:{d}: unknown key `{s}` in a component table (sha256, size)", .{ line_no, key });
            }
        } else {
            diag.add("buildrules-pins.toml:{d}: unknown key `{s}` (a version table holds only component tables; the URLs are the versioned ones, so there is no date)", .{ line_no, key });
        }
    }
    for (rows.items) |r| {
        for (components, 0..) |c, i| {
            if (r.comp[i].sha256 == null or r.comp[i].size == null or r.comp[i].size.? == 0) {
                diag.add("buildrules-pins.toml: rust \"{s}\" component {s} needs both sha256 and size", .{ r.version, c });
            }
        }
    }
    if (diag.count() != before) return error.Invalid;

    std.mem.sort(Row, rows.items, {}, struct {
        fn lt(_: void, x: Row, y: Row) bool {
            return std.mem.lessThan(u8, x.version, y.version);
        }
    }.lt);
    var o = std.ArrayList(u8).empty;
    o.appendSlice(a, header) catch return error.Invalid;
    if (rows.items.len == 0) {
        o.appendSlice(a, "EXTRA_RUST_VERSIONS = {}\n") catch return error.Invalid;
        return o.toOwnedSlice(a) catch error.Invalid;
    }
    o.appendSlice(a, "EXTRA_RUST_VERSIONS = {\n") catch return error.Invalid;
    for (rows.items) |r| {
        o.print(a, "    \"{s}\": {{\n", .{r.version}) catch return error.Invalid;
        for (components, 0..) |c, i| {
            var key: [16]u8 = undefined;
            @memcpy(key[0..c.len], c);
            std.mem.replaceScalar(u8, key[0..c.len], '-', '_');
            o.print(a, "        \"{s}\": {{\"sha256\": \"{s}\", \"size\": {d}}},\n", .{ key[0..c.len], r.comp[i].sha256.?, r.comp[i].size.? }) catch return error.Invalid;
        }
        o.appendSlice(a, "    },\n") catch return error.Invalid;
    }
    o.appendSlice(a, "}\n") catch return error.Invalid;
    return o.toOwnedSlice(a) catch error.Invalid;
}

pub const header =
    "# Generated by `buildrules sync` from buildrules-pins.toml. Do not edit.\n" ++
    "# The Rust versions this repository pins itself, beyond rules/rust/pins.bzl (docs/contract.md, section 6).\n";

/// What toolchains/rust_pins.bzl holds in a repository with no buildrules-pins.toml.
pub const empty = header ++ "EXTRA_RUST_VERSIONS = {}\n";
