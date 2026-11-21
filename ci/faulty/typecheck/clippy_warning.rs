// Well typed, with one clippy warning and no rustc warning (ci/faulty/BUCK): the type check is green, clippy under `-D warnings` is red.
pub fn answer() -> u32 {
    return 42;
}
