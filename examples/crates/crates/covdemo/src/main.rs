//! The binary of covdemo: it only forwards to the library.

fn main() {
    let name = std::env::args().nth(1).unwrap_or_default();
    println!("{}", covdemo::greet(&name));
}
