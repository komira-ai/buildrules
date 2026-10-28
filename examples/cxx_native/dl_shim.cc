// The one symbol the shared object exports. Everything else it holds (the archive of `shapes`, libc++, libc++abi, libunwind) is hidden, so the object can be
// loaded into a process that has a C++ runtime of its own without the two meeting.
extern "C" int shapes_sides(unsigned n);

extern "C" __attribute__((visibility("default"))) int shapes_dl_sides(unsigned n) { return shapes_sides(n); }
