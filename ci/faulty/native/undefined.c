/* KNOWN DEFECT: calls a function that nothing in the library, no `needs` library and no C library defines. */
int faulty_missing_helper(int);

int faulty_native_twice(int x) { return faulty_missing_helper(x) * 2; }
