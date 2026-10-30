/* split_value() = 42, in x86-64 assembly: a macro of two instructions joined with `;`, which GNU-style assemblers read as two statements. */
#include "compat/asm_names.h"

#define SEVEN_PLUS_35 movl $7, %eax; addl $35, %eax

    .text
    .globl SYM(split_value)
    .type SYM(split_value), @function
SYM(split_value):
    SEVEN_PLUS_35
    ret
    .size SYM(split_value), .-SYM(split_value)

    .section .note.GNU-stack, "", @progbits
