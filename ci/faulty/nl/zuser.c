#include <zlib.h>

/* Includes the header of the zlib tree: it compiles only with the library that exports the tree among its deps. */
int nl_zver(void) { return ZLIB_VERNUM; }
