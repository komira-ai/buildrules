/* A library that renames its C API and keeps the mangled name of a C++ namespace: the name is written as the compiler would write it, and a header of macros leaves it alone. */
int _ZN6snappy3fooEv(void) { return 7; }

int faulty_prefixed_ns_api(void) { return _ZN6snappy3fooEv(); }
