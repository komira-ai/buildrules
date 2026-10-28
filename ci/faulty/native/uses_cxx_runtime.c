/* KNOWN DEFECT: a C library that calls the C++ runtime (operator new). Only a library declared `c++` may leave that undefined: its final link brings the runtime. */
void *_Znwm(unsigned long);

void *faulty_native_alloc(unsigned long n) { return _Znwm(n); }
