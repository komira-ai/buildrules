// KNOWN DEFECT: a C++ library that leaves undefined a function of libstdc++, which the C++ runtime of the final link (libc++) does not define.
namespace std {
void __throw_length_error(const char *);
}

extern "C" void faulty_cxx_throw(unsigned n) {
    if (n > 100) std::__throw_length_error("too long");
}
