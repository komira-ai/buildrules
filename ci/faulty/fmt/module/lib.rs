//! A root rustfmt leaves as it is, with a module it would change: rustfmt follows `mod` to it.

mod inner;

pub use inner::answer;
