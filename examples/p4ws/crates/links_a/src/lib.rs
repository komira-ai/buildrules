//! Carries the `links` key; `P4_LINKS_A` is set by its script's cfg.
pub fn has_cfg() -> bool {
    cfg!(p4_links_a)
}

#[cfg(test)]
mod tests {
    #[test]
    fn cfg_from_script() {
        assert!(super::has_cfg());
    }
}
