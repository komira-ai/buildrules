//! The library root of tools/channels: what a release channel needs that is not the release itself.
//!
//!   tar.zig      byte-deterministic ustar and gzip, and a reader for them
//!   control.zig  Debian control-file syntax
//!   deb.zig      a .deb written byte-deterministically
//!   deb_package.zig  the build half's one entry point: a binary and its metadata in, a .deb out (the shape of buildrules' deb_package)
//!   apt.zig      Packages / Packages.gz / Release, merging a new .deb into an index, monotonic and bounded
//!   formula.zig  the Homebrew formula from SHA256SUMS
//!   version.zig  X.Y.Z and the rule that a channel never moves down
//!
//! Provenance. Vendored from the sibling tool `mopm`, which publishes these channels today: its main at commit 3ace214, with the heads of its open pull requests 149 (commit
//! 9371124, the apt publish: the shared Release fields, the by-hash files and the three jobs) and 150 (commit ccac8e0, the formula without a version line). It is a
//! stopgap until `deb_package` and `brew_formula` rules and the deploy of the apt repository exist: the files are the sibling's, renamed for this repository, with the
//! changes the sources say (the asset stem of the formula, the product's pool directory, dates after the scrub's cutoff). Re-pin the commit when those pull requests merge.
//!
//! `main.zig` is the command line over these. This root exists so one test target runs the tests of all of them.

pub const tar = @import("tar.zig");
pub const control = @import("control.zig");
pub const deb = @import("deb.zig");
pub const deb_package = @import("deb_package.zig");
pub const apt = @import("apt.zig");
pub const formula = @import("formula.zig");
pub const version = @import("version.zig");

test {
    _ = tar;
    _ = control;
    _ = deb;
    _ = deb_package;
    _ = apt;
    _ = formula;
    _ = version;
    _ = @import("golden_test.zig");
}
