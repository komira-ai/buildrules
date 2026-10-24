/* libshim.a: the native library of the package rooted_native, in a directory below the repository root. */
#include "rshim.h"

int rshim_add(int a, int b) { return a + b; }

int rshim_scale(int x) { return rshim_add(x, x) * 3; }
