// A type error only the test target compiles (ci/faulty/BUCK): the library's type check is green, the test target's is red.
pub fn answer() -> u32 {
    42
}

#[cfg(test)]
mod tests {
    #[test]
    fn answer_is_a_number() {
        let n: u32 = super::answer() + "one";
        assert_eq!(n, 43);
    }
}
