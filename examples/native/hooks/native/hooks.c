#include <stddef.h>

/* A hook the library calls if a program defines it: weak, and not defined here. `prefix` renames the names the library defines; this one it only refers to, so it is named in
   the prefix's extra_symbols. */
__attribute__((weak)) void *hook_alloc(size_t n);

/* The hook's answer when a program defines it, 0 when it does not. */
long hooks_alloc(long n) { return hook_alloc ? (long)(size_t)hook_alloc((size_t)n) : 0; }
