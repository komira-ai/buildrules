/* split_value() = 42, in AArch64 assembly: a macro of two instructions joined with `;`. In Mach-O arm64 assembly `;` starts a comment, so the second instruction is lost unless the
   preprocessed text has its `;` turned into line breaks first (`asm_split`): the function then returns 7. */
#include "compat/asm_names.h"

#define SEVEN_PLUS_35 mov x0, #7; add x0, x0, #35

    .text
    .globl SYM(split_value)
    .p2align 2
SYM(split_value):
    SEVEN_PLUS_35
    ret
