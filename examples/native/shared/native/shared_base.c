#include "shared/shared_base.h"

static int inits;

/* Runs once for each copy of this object a program links, before main. */
__attribute__((constructor)) static void shared_base_init(void) { inits++; }

int shared_base_value(void) { return 10; }

int shared_init_count(void) { return inits; }
