// Links the archive of the native library `shapes` (not its sources) and calls it: 4 sides and 3 words.
#include <cstdio>

extern "C" int shapes_sides(unsigned n);

int main() {
    std::printf("shapes %d\n", shapes_sides(3));
    return 0;
}
