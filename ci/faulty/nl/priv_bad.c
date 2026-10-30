#include "p/priv.h"

/* Includes a private header of its dependency, which the dependency does not export. */
int nl_bad(void) { return nl_priv() + 1; }
