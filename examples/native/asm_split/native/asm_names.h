/* The symbol of a C name in assembly: Mach-O puts an underscore before it, ELF does not. */
#ifndef ASM_NAMES_H
#define ASM_NAMES_H

#if defined(__APPLE__)
#define SYM(name) _##name
#else
#define SYM(name) name
#endif

#endif
