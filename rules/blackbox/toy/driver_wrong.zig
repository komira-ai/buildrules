//! The toy's driver expecting another answer than the service gives (driver.zig): the driver of the black-box test that is red by design
//! (ci/faulty, `blackbox_test_whose_driver_fails`, and the process cases of rules/blackbox).

pub fn main() u8 {
    return @import("driver.zig").drive("service saw: another answer");
}
