//! stamped: the commit this crate was built from, as its build script embedded it.

#[path = "../../../shared/stamp.rs"]
mod stamp;

pub use stamp::{OVERRIDE, UNKNOWN};

/// The commit `git` names, or the stamp that replaced it.
pub const BUILD_COMMIT: &str = env!("FIXTURE_BUILD_COMMIT");

/// The commit given by the variable [`OVERRIDE`] to the build script, or [`UNKNOWN`].
pub const GIVEN_COMMIT: &str = env!("FIXTURE_GIVEN_COMMIT");

// These hold under buildrules, where BUCK gives the stamp. Under plain cargo the commit is git's and the variable is unset.
#[cfg(test)]
mod tests {
    use super::*;

    /// The text of build_commit.txt, the stamp BUCK gives.
    const STAMP: &str = "build-commit-from-an-input";

    #[test]
    fn the_commit_is_the_stamp_given_as_an_input() {
        assert_eq!(BUILD_COMMIT, STAMP, "the commit is not the stamp given as an input");
    }

    #[test]
    fn the_override_variable_is_the_stamp_given_as_an_input() {
        assert_eq!(GIVEN_COMMIT, STAMP, "the override variable is not the stamp given as an input");
    }

    #[test]
    fn the_stamp_is_not_the_text_for_no_commit() {
        assert_ne!(BUILD_COMMIT, UNKNOWN);
        assert_eq!(OVERRIDE, "FIXTURE_BUILD_COMMIT_OVERRIDE");
    }
}
