/* Loads the shared object named by argv[1] the way a JIT or a REPL loads a library at run time, and calls it. This program is C and links no C++ runtime: the
   object must bring its own. It prints "dl 7" when the object works, and that it exports nothing of the C++ runtime (operator new, the unwinder). */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 3;
    }
    int (*sides)(unsigned) = (int (*)(unsigned))dlsym(h, "shapes_dl_sides");
    if (!sides) return 4;
    if (dlsym(h, "_Znwm") || dlsym(h, "_ZdlPv") || dlsym(h, "__cxa_pure_virtual") || dlsym(h, "_Unwind_RaiseException") || dlsym(h, "shapes_sides")) return 5;
    printf("dl %d\n", sides(3));
    return 0;
}
