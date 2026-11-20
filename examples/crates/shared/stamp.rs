//! The names of the stamp, shared by `crates/stamped`'s build script and library through `#[path]`: a source outside the crate's directory.

/// The variable the build script prefers to `git` when it is set.
pub const OVERRIDE: &str = "FIXTURE_BUILD_COMMIT_OVERRIDE";

/// What the build says when it knows no commit.
pub const UNKNOWN: &str = "unknown";
