#include <stddef.h>

/* The program's side of the hooks of the prefixed library: the name is the prefixed one (`hk_` and the hook). */
void *hk_hook_alloc(size_t n) { return (void *)(size_t)(n + 40); }
