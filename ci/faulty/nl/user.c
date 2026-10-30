#include "nl/lib.h"

/* Includes the header of nl_lib: it compiles only with nl_lib among its deps. */
int nl_user(void) { return nl_value() + 1; }
