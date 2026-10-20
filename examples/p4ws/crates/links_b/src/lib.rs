pub const SEEN: &str = env!("P4_SEEN");
pub const OUT_COPY: &str = include_str!(concat!(env!("OUT_DIR"), "/seen.txt"));

#[cfg(test)]
mod tests {
    #[test]
    fn dep_vars_arrive() {
        assert_eq!(super::SEEN, "42|hello world|from-links-a");
        assert_eq!(super::OUT_COPY, super::SEEN);
        assert!(links_a::has_cfg());
    }
}
