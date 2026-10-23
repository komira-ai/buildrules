// A stand-in for a pinned third-party specification a test reads whole (a package's tests may open a .thrift file that is not theirs to change).
struct Example {
  1: required i32 id
  2: optional string label
}
