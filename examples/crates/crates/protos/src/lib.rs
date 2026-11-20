//! protos: the messages, the service trait and the client compiled from `proto/` (and the shared protos it imports) by the build script.

mod names;

pub use names::FILES;

/// The encoded descriptor set of [`FILES`] and of every file they import, as the build script wrote it.
pub const FILE_DESCRIPTOR_SET: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/fixture.binpb"));

/// The shared protos (`../../shared/proto`).
pub mod common {
    pub mod v1 {
        tonic::include_proto!("common.v1");
    }
}

/// This crate's own protos (`proto/`).
pub mod fixture {
    pub mod v1 {
        tonic::include_proto!("fixture.v1");
    }
}
