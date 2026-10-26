/* A native library as it should be: it defines its own symbols and calls the C library. */
#include <string.h>

int faulty_native_sum(const int *xs, unsigned n) {
    int s = 0;
    for (unsigned i = 0; i < n; i++) s += xs[i];
    return s;
}

void faulty_native_copy(char *dst, const char *src, unsigned n) { memcpy(dst, src, n); }
