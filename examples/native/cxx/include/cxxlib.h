/* cxxlib: the C ABI of the C++ library of examples/native/cxx. Mojo and C call these; the C++ behind them is in native/cxxlib.cc. */
#ifndef CXXLIB_H
#define CXXLIB_H

#ifdef __cplusplus
extern "C" {
#endif

/* How many entries the static initializer of cxxlib.cc put in its registry before main: 3. */
int cxxlib_registered(void);

/* The length of "hello, " followed by `n` letters, built as a std::string. */
unsigned cxxlib_greeting_len(int n);

/* The sum of the first `n` terms of a class hierarchy with a virtual call, found through dynamic_cast: 0 + 1 + ... + (n - 1) scaled by 2. */
int cxxlib_scaled_sum(int n);

/* 1 when an exception thrown below this call (std::runtime_error) is caught by it, 0 when nothing was thrown. */
int cxxlib_caught(int do_throw);

#ifdef __cplusplus
}
#endif

#endif
