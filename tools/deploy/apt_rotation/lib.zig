//! The library root of tools/deploy/apt_rotation.zig, the keyring-rotation proof: what it reads out of gpg, gpgv and apt-get. `../apt_rotation.zig` is the command
//! line over these (it runs the processes); this root exists so one test target runs the tests of all of them.

pub const parse = @import("parse.zig");

test {
    _ = parse;
}
