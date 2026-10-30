/* Declares what it calls itself: it does not include the private header of its dependency. */
int nl_priv(void);

int nl_ok(void) { return nl_priv() + 1; }
