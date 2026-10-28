// A C++ native static library: operator new and delete, a pure virtual function (the stub __cxa_pure_virtual), a virtual destructor, and libc++'s std::string and
// std::vector. All of the C++ runtime comes with the final link; the archive defines none of it.
#include "shapes.h"

#include <string>
#include <vector>

namespace {

struct Shape {
    virtual ~Shape() {}
    virtual int sides() const = 0;
};

struct Square : Shape {
    int sides() const override { return 4; }
};

}  // namespace

extern "C" int shapes_sides(unsigned n) {
    Shape *s = new Square;
    std::vector<std::string> words;
    for (unsigned i = 0; i < n; i++) words.push_back(std::string("w") + std::to_string(i));
    int total = s->sides() + static_cast<int>(words.size());
    delete s;
    return total;
}
