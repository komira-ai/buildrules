/* A renamed native library as it should be: every symbol it defines is renamed by the header, and it calls its own other symbol and the C library. */
#include <string.h>

int faulty_prefixed_one(void) { return 1; }

void faulty_prefixed_copy(char *dst, const char *src, unsigned n) { memcpy(dst, src, n); }
