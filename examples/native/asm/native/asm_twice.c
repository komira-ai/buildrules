/* The C half of the library: it calls the assembly, so one archive holds both languages. */
long long asm_add(long long a, long long b);

long long asm_twice(long long x) { return asm_add(x, x); }
