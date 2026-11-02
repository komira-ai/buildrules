/* KNOWN DEFECT: the call names the symbol by an assembler label, which the renaming header cannot reach: the library defines the renamed symbol and calls the old name. */
int faulty_prefixed_target_by_label(void) __asm__("faulty_prefixed_target");

int faulty_prefixed_user(void) { return faulty_prefixed_target_by_label() + 1; }
