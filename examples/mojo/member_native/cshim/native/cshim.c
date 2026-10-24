/* libshim.a: the native library of the member package cshim. It defines its own symbols and calls the C library. */
#include <string.h>

#include "cshim.h"

int cshim_add(int a, int b) { return a + b; }

int cshim_scale(int x) { return cshim_add(x, x) * 3; }

unsigned cshim_len(const char *s) { return (unsigned)strlen(s); }
