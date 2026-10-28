#ifndef EXAMPLES_CXX_NATIVE_SHAPES_H_
#define EXAMPLES_CXX_NATIVE_SHAPES_H_

extern "C" {
// Sides of a shape (4: a square), plus the length of a string the library builds with `new` and libc++'s std::string for `n`.
int shapes_sides(unsigned n);
}

#endif
