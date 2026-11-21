//! Publishes metadata for the build scripts of the packages that depend on this one, as a package with `links` does.

fn main() {
    // cargo sets CARGO_MANIFEST_LINKS to the package's `links` for its build script; the run fails without it.
    let links = std::env::var("CARGO_MANIFEST_LINKS").expect("CARGO_MANIFEST_LINKS is set for the build script of a package with `links`");
    println!("cargo::rustc-env=LINKED_LINKS={links}");
    println!("cargo::metadata=greeting=hello from {links}");
}
