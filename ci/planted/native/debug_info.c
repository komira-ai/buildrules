/* PLANTED DEFECT: the object carries a debug section (the assembler directive stands in for DWARF that records the directory the file was compiled in). */
__asm__(".section .debug_planted,\"\",@progbits\n\t.byte 1\n\t.previous\n");

int planted_native_one(void) { return 1; }
