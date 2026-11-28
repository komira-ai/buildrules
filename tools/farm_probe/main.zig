//! The farm_probe program: `probe.run` given the kernel. Each method of `Kernel` is one Linux system call with its raw result and no
//! decision of its own; every decision is in probe.zig, whose tests (probe_test.zig) drive each outcome through a fake. This file is
//! left out of the package's coverage `expect` (BUCK says why).

const std = @import("std");
const linux = std.os.linux;
const probe = @import("probe.zig");

const Kernel = struct {
    pub fn open(_: Kernel, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) usize {
        return linux.open(path, flags, mode);
    }
    pub fn read(_: Kernel, fd: i32, buf: []u8) usize {
        return linux.read(fd, buf.ptr, buf.len);
    }
    pub fn write(_: Kernel, fd: i32, bytes: []const u8) usize {
        return linux.write(fd, bytes.ptr, bytes.len);
    }
    pub fn close(_: Kernel, fd: i32) usize {
        return linux.close(fd);
    }
    pub fn unlink(_: Kernel, path: [*:0]const u8) usize {
        return linux.unlink(path);
    }
    pub fn mkdir(_: Kernel, path: [*:0]const u8, mode: linux.mode_t) usize {
        return linux.mkdir(path, mode);
    }
    pub fn rmdir(_: Kernel, path: [*:0]const u8) usize {
        return linux.rmdir(path);
    }
    pub fn access(_: Kernel, path: [*:0]const u8, mode: u32) usize {
        return linux.faccessat(linux.AT.FDCWD, path, mode, 0);
    }
    pub fn uname(_: Kernel, uts: *linux.utsname) usize {
        return linux.uname(uts);
    }
    pub fn getrlimit(_: Kernel, res: linux.rlimit_resource, lim: *linux.rlimit) usize {
        return linux.getrlimit(res, lim);
    }
    pub fn affinity(_: Kernel, set: *linux.cpu_set_t) usize {
        return linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), set);
    }
    pub fn getcwd(_: Kernel, buf: []u8) usize {
        return linux.getcwd(buf.ptr, buf.len);
    }
    pub fn getpid(_: Kernel) i32 {
        return linux.getpid();
    }
    pub fn getuid(_: Kernel) u32 {
        return linux.getuid();
    }
    pub fn getgid(_: Kernel) u32 {
        return linux.getgid();
    }
    pub fn socket(_: Kernel, domain: u32, kind: u32, protocol: u32) usize {
        return linux.socket(domain, kind, protocol);
    }
    pub fn ioctl(_: Kernel, fd: i32, request: u32, req: *linux.ifreq) usize {
        return linux.ioctl(fd, request, @intFromPtr(req));
    }
    pub fn bind(_: Kernel, fd: i32, addr: *const linux.sockaddr.in) usize {
        return linux.bind(fd, @ptrCast(addr), @sizeOf(linux.sockaddr.in));
    }
    pub fn listen(_: Kernel, fd: i32, backlog: u32) usize {
        return linux.listen(fd, backlog);
    }
    pub fn getsockname(_: Kernel, fd: i32, addr: *linux.sockaddr.in) usize {
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        return linux.getsockname(fd, @ptrCast(addr), &len);
    }
    pub fn connect(_: Kernel, fd: i32, addr: *const linux.sockaddr.in) usize {
        return linux.connect(fd, addr, @sizeOf(linux.sockaddr.in));
    }
    pub fn accept(_: Kernel, fd: i32) usize {
        return linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
    }
    pub fn poll(_: Kernel, fds: []linux.pollfd, timeout_ms: i32) usize {
        return linux.poll(fds.ptr, fds.len, timeout_ms);
    }
    pub fn sockError(_: Kernel, fd: i32, err: *i32) usize {
        var len: linux.socklen_t = @sizeOf(i32);
        return linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(err), &len);
    }
    pub fn unshare(_: Kernel, flags: usize) usize {
        return linux.unshare(flags);
    }
    pub fn mount(_: Kernel, source: [*:0]const u8, dir: [*:0]const u8, fstype: [*:0]const u8, flags: u32, data: [*:0]const u8) usize {
        return linux.mount(source, dir, fstype, flags, @intFromPtr(data));
    }
    pub fn umount(_: Kernel, dir: [*:0]const u8) usize {
        return linux.umount2(dir, 0);
    }
};

pub fn main() u8 {
    var buf: [65536]u8 = undefined;
    return probe.run(Kernel{}, std.os.argv[1..], std.os.environ, &buf);
}
