/* KNOWN DEFECT: the symbol is named by an assembler label, which the renaming header (a macro) cannot reach, so the library defines a name without the prefix. */
int faulty_prefixed_fixed(void) __asm__("faulty_prefixed_fixed");

int faulty_prefixed_fixed(void) { return 3; }

int faulty_prefixed_other(void) { return 4; }
