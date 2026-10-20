/* The C twin of examples/isa/src/lib.rs: one loop the vectorizer widens with the target's SIMD registers.
   `noinline` keeps one out-of-line copy for the disassembly. */
#include <stdint.h>
#include <stdio.h>

__attribute__((noinline)) uint32_t sum(const uint32_t *a, unsigned n) {
    uint32_t s = 0;
    for (unsigned i = 0; i < n; i++) s += a[i];
    return s;
}

int main(void) {
    uint32_t v[1000];
    for (unsigned i = 0; i < 1000; i++) v[i] = i + 1;
    printf("%u\n", (unsigned)sum(v, 1000));
    return 0;
}
