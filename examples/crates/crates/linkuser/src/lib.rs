//! What this package's build script read from its dependencies with `links` (crates/linkuser/build.rs).

/// The `greeting` metadata of crates/linked (DEP_FIXTURE_LINKED_GREETING).
pub const GREETING: &str = env!("LINKUSER_GREETING");

/// The version in the zstd.h of zstd-sys's include directory (DEP_ZSTD_INCLUDE).
pub const ZSTD_HEADER_VERSION: &str = env!("LINKUSER_ZSTD_HEADER_VERSION");

#[cfg(test)]
mod tests {
    #[test]
    fn the_metadata_of_a_member_with_links_reached_the_build_script() {
        assert_eq!(super::GREETING, format!("hello from {}", linked::LINKS));
        assert_eq!(super::GREETING, "hello from fixture_linked");
    }

    #[test]
    fn the_include_directory_of_a_registry_crate_with_links_reached_the_build_script() {
        // zstd-sys 2.0.9+zstd.1.5.5 (Cargo.lock): the header its script published is the one of the zstd it compiled.
        assert_eq!(super::ZSTD_HEADER_VERSION, "1.5.5");
    }
}
