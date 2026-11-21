//! The `links` value this package's build script was run with (crates/linked/build.rs).

/// The package's `links`, as its build script read it from CARGO_MANIFEST_LINKS.
pub const LINKS: &str = env!("LINKED_LINKS");

#[cfg(test)]
mod tests {
    #[test]
    fn the_build_script_ran_with_the_links_of_its_package() {
        assert_eq!(super::LINKS, "fixture_linked");
    }
}
