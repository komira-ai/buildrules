#include "cxxlib.h"

/* A C library over the C++ library: its closure has C++ sources, so a program that links it links the C++ runtime, though it names no C++ library itself. */
int cuser_registered(void) { return cxxlib_registered() + 100; }
