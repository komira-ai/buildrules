//! Compiles the protos of `proto/` and the shared ones they import (`../../shared/proto`) into Rust, and writes their descriptor set.
//!
//! `protox` parses the `.proto` files in pure Rust, so the build needs no `protoc`; `tonic-prost-build` turns the descriptors into messages, a
//! service trait and a client, with no transport. The list of files is `src/names.rs`, which the library reads too. Nothing generated is checked
//! in: it lands in `OUT_DIR`.

#[path = "src/names.rs"]
mod names;

use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // A build script runs in its package's directory.
    let mut compiler = protox::Compiler::new(["proto", "../../shared/proto"])?;
    compiler.include_imports(true).include_source_info(true);
    compiler.open_files(names::FILES)?;

    let out = PathBuf::from(std::env::var_os("OUT_DIR").ok_or("cargo set no OUT_DIR")?);
    std::fs::write(out.join("fixture.binpb"), compiler.encode_file_descriptor_set())?;

    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        .build_transport(false)
        // A host's params encode in the order of their keys, so a message encodes to the same bytes on every run.
        .btree_map(".fixture.v1.Host.params")
        .compile_fds(compiler.file_descriptor_set())?;

    println!("cargo:rerun-if-changed=proto");
    println!("cargo:rerun-if-changed=../../shared/proto");
    println!("cargo:rerun-if-changed=src/names.rs");
    Ok(())
}
