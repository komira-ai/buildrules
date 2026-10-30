/* asm_add(a, b) = a + b + ASM_BIAS, and asm_isa() = 1, in x86-64 assembly (System V). ASM_BIAS is a flag of the library (`asm_flags`). */
#include "compat/asm_names.h"

    .text
    .globl SYM(asm_add)
    .type SYM(asm_add), @function
SYM(asm_add):
    leaq ASM_BIAS(%rdi, %rsi), %rax
    ret
    .size SYM(asm_add), .-SYM(asm_add)

    .globl SYM(asm_isa)
    .type SYM(asm_isa), @function
SYM(asm_isa):
    movl $1, %eax
    ret
    .size SYM(asm_isa), .-SYM(asm_isa)

    .section .note.GNU-stack, "", @progbits
