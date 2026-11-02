// libcxxlib.a, in C++. It has a class with a virtual function, a static initializer that runs before main,
// std::string and std::vector from the standard library, RTTI (dynamic_cast) and an exception thrown and caught inside it: everything the final link
// must take from the C++ runtime (libc++ and libc++abi). Nothing crosses the C ABI but ints and a C string.
#include <stdexcept>
#include <string>
#include <vector>

#include "cxxlib.h"

namespace {

struct Term {
  virtual ~Term() {}
  virtual int value() const = 0;
};

struct Linear : Term {
  explicit Linear(int i) : i_(i) {}
  int value() const override { return i_; }
  int i_;
};

std::vector<std::string> make_registry() {
  std::vector<std::string> r;
  r.push_back("a");
  r.push_back("b");
  r.push_back("c");
  return r;
}

// A static initializer: constructed before main, by the dynamic initialization of the archive's object, not by a call.
const std::vector<std::string> registry = make_registry();

}  // namespace

extern "C" {

int cxxlib_registered(void) { return static_cast<int>(registry.size()); }

unsigned cxxlib_greeting_len(int n) {
  std::string s("hello, ");
  s += std::string(static_cast<size_t>(n), 'x');
  return static_cast<unsigned>(s.size());
}

int cxxlib_scaled_sum(int n) {
  int sum = 0;
  for (int i = 0; i < n; i++) {
    Linear term(i);
    const Term *t = &term;
    const Linear *l = dynamic_cast<const Linear *>(t);
    sum += l->value();
  }
  return sum * 2;
}

int cxxlib_caught(int do_throw) {
  try {
    if (do_throw) throw std::runtime_error("thrown below the C ABI");
  } catch (const std::exception &) {
    return 1;
  }
  return 0;
}

}  // extern "C"
