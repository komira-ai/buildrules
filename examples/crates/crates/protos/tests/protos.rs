//! What the build script generated, used as a caller would: the messages, the service trait, and the descriptor set.

use std::collections::BTreeMap;

use prost::Message;
use protos::common::v1::Label;
use protos::fixture::v1::hosts_server::{self, Hosts};
use protos::fixture::v1::{Host, ListHostsRequest, ListHostsResponse};
use tonic::{Request, Response, Status};

fn host(name: &str) -> Host {
    Host { name: name.to_owned(), slots: 2, labels: Vec::new(), params: BTreeMap::new() }
}

#[test]
fn a_host_encodes_to_its_protobuf_bytes() {
    // field 1 (name, length-delimited) "a", field 2 (slots, varint) 2
    assert_eq!(host("a").encode_to_vec(), vec![0x0a, 0x01, b'a', 0x10, 0x02]);
}

#[test]
fn a_host_with_a_shared_label_decodes_to_the_same_message() {
    let mut h = host("node-a");
    h.labels.push(Label { key: "rack".to_owned(), value: "r1".to_owned() });
    let bytes = h.encode_to_vec();
    assert_eq!(Host::decode(&bytes[..]).unwrap(), h);
}

#[test]
fn params_encode_in_the_order_of_their_keys() {
    let mut first = host("a");
    first.params.insert("z".to_owned(), "1".to_owned());
    first.params.insert("a".to_owned(), "2".to_owned());
    let mut second = host("a");
    second.params.insert("a".to_owned(), "2".to_owned());
    second.params.insert("z".to_owned(), "1".to_owned());
    assert_eq!(first.encode_to_vec(), second.encode_to_vec());
}

#[test]
fn truncated_bytes_are_refused() {
    // field 1 says five bytes follow, and one does
    assert!(Host::decode(&[0x0a, 0x05, b'a'][..]).is_err());
}

#[test]
fn the_descriptor_set_holds_every_file_and_the_shared_import() {
    let set = prost_types::FileDescriptorSet::decode(protos::FILE_DESCRIPTOR_SET).unwrap();
    let mut names: Vec<&str> = set.file.iter().map(|f| f.name()).collect();
    names.sort_unstable();
    assert_eq!(names, ["common/v1/labels.proto", "fixture/v1/hosts.proto", "fixture/v1/service.proto"]);
    let mut listed = protos::FILES.to_vec();
    listed.sort_unstable();
    assert!(listed.iter().all(|f| names.contains(f)));
}

#[test]
fn the_service_is_named_by_its_proto_package() {
    assert_eq!(hosts_server::SERVICE_NAME, "fixture.v1.Hosts");
}

/// A service over a fixed list of hosts.
struct Fixed(Vec<Host>);

#[tonic::async_trait]
impl Hosts for Fixed {
    async fn list_hosts(&self, request: Request<ListHostsRequest>) -> Result<Response<ListHostsResponse>, Status> {
        let prefix = request.into_inner().prefix;
        if prefix.is_empty() {
            return Err(Status::invalid_argument("a prefix is required"));
        }
        let hosts = self.0.iter().filter(|h| h.name.starts_with(&prefix)).cloned().collect();
        Ok(Response::new(ListHostsResponse { hosts }))
    }
}

#[tokio::test]
async fn the_generated_service_trait_answers_through_an_implementation() {
    let service = Fixed(vec![host("node-a"), host("node-b"), host("mac-a")]);
    let answer = service.list_hosts(Request::new(ListHostsRequest { prefix: "node-".to_owned() })).await.unwrap();
    let names: Vec<String> = answer.into_inner().hosts.into_iter().map(|h| h.name).collect();
    assert_eq!(names, ["node-a", "node-b"]);
}

#[tokio::test]
async fn the_generated_service_trait_carries_a_refusal() {
    let service = Fixed(vec![host("node-a")]);
    let status = service.list_hosts(Request::new(ListHostsRequest { prefix: String::new() })).await.unwrap_err();
    assert_eq!(status.code(), tonic::Code::InvalidArgument);
    assert_eq!(status.message(), "a prefix is required");
}
