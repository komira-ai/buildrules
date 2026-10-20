//! The library of the hello example.

pub fn greeting(name: &str) -> String {
    format!("hello, {name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greets_by_name() {
        assert_eq!(greeting("buildrules"), "hello, buildrules");
    }
}
