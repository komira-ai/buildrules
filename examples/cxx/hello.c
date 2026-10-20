/* A C program for the hermeticity check (BUCK): it prints one line, so it also shows that a binary linked with debug info stripped still runs. */
#include <stdio.h>

int main(void) {
    puts("hello from C");
    return 0;
}
