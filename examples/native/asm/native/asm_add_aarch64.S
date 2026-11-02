/* asm_add(a, b) = a + b + ASM_BIAS, and asm_isa() = 2, in AArch64 assembly (AAPCS64; the Apple arm64 ABI differs from it only in the symbol's underscore). */
#include "compat/asm_names.h"

    .text
    .globl SYM(asm_add)
    .p2align 2
SYM(asm_add):
    add x0, x0, x1
    add x0, x0, #ASM_BIAS
    ret

    .globl SYM(asm_isa)
    .p2align 2
SYM(asm_isa):
    mov w0, #2
    ret
