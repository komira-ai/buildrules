//! PLANTED: reads an environment variable the contract does not declare. Must fail on the farm.
fn main() {
    let v = std::env::var("P4_UNDECLARED").expect("undeclared env var P4_UNDECLARED");
    println!("cargo:rustc-env=P4_V={v}");
}
