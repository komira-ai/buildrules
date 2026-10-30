#include "base/base.h"
#include "mid.h"

/* mid_value() + 1: `mid` re-exports `base` (exported_deps), so this file sees base/base.h as well as mid.h. */
int top_value(void) { return mid_value() + base_value() - 40 + 1; }
