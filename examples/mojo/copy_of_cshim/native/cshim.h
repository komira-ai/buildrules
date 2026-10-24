/* cshim: the C shim of the member package `cshim` (its `[native.shim]`). */
#ifndef CSHIM_H
#define CSHIM_H

int cshim_add(int a, int b);

/* Three times the sum of x with itself. */
int cshim_scale(int x);

/* The length of a NUL-terminated string, through the C library. */
unsigned cshim_len(const char *s);

#endif
