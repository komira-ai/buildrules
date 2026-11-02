#include "nl/lib.h"

/* Includes the header of nl_lib, which nl_mid_plain uses but does not re-export. */
int nl_top(void) { return nl_value() + 2; }
