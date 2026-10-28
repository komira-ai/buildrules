// A C++ native library as it should be: new, delete, a pure virtual function and a libc++ string, all of the C++ runtime its final link brings.
#include <string>

struct Shape {
    virtual ~Shape() {}
    virtual int sides() const = 0;
};

struct Square : Shape {
    int sides() const override { return 4; }
};

extern "C" int faulty_cxx_sides(unsigned n) {
    Shape *s = new Square;
    std::string text(n, 'x');
    int r = s->sides() + static_cast<int>(text.size());
    delete s;
    return r;
}
