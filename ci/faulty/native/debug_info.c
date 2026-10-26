/* KNOWN DEFECT: the object carries a debug section (the assembler directive stands in for DWARF that records the directory the file was compiled in). */
__asm__(".section .debug_faulty,\"\",@progbits\n\t.byte 1\n\t.previous\n");

int faulty_native_one(void) { return 1; }
