fn main() {
    let v: Vec<u32> = (1..=1000).collect();
    println!("{} {}", isa_lib::level(), isa_lib::sum(&v));
}
