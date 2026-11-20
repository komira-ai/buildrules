//! gdemo: an error type derived by thiserror, a dependency taken from its git repository at a pinned commit.
//!
//! The derive is a proc-macro of that repository (thiserror-impl, in its impl/ directory); under buildrules it is compiled once from
//! the repository's GitHub archive and loaded by rustc for this crate.

use thiserror::Error;

/// Why a size could not be read.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum SizeError {
    /// The text is empty.
    #[error("no size given")]
    Empty,
    /// The text is not a number.
    #[error("`{0}` is not a size in bytes")]
    NotANumber(String),
    /// The number is larger than the limit.
    #[error("{size} bytes is more than the limit of {limit}")]
    TooLarge { size: u64, limit: u64 },
}

/// The size `text` names, at most `limit` bytes.
pub fn parse_size(text: &str, limit: u64) -> Result<u64, SizeError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(SizeError::Empty);
    }
    let size: u64 = text.parse().map_err(|_| SizeError::NotANumber(text.to_string()))?;
    if size > limit {
        return Err(SizeError::TooLarge { size, limit });
    }
    Ok(size)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_size_within_the_limit_is_read() {
        assert_eq!(parse_size(" 512 ", 1024), Ok(512));
        assert_eq!(parse_size("1024", 1024), Ok(1024));
    }

    #[test]
    fn each_refusal_says_what_was_wrong_in_the_derived_message() {
        assert_eq!(parse_size("", 10).unwrap_err().to_string(), "no size given");
        assert_eq!(parse_size("ten", 10).unwrap_err().to_string(), "`ten` is not a size in bytes");
        assert_eq!(parse_size("11", 10).unwrap_err().to_string(), "11 bytes is more than the limit of 10");
    }

    #[test]
    fn the_derived_type_is_a_std_error() {
        fn takes(_: &dyn std::error::Error) {}
        takes(&SizeError::Empty);
    }
}
