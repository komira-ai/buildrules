//! The proto files this crate compiles, read by the build script (through `#[path]`) and by the library: one list for both.

/// Every file under `proto/`, as protox opens it. The files they import come along (`include_imports`).
pub const FILES: &[&str] = &["fixture/v1/hosts.proto", "fixture/v1/service.proto"];
