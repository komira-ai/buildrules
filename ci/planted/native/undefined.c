/* PLANTED DEFECT: calls a function that nothing in the library, no `needs` library and no C library defines. */
int planted_missing_helper(int);

int planted_native_twice(int x) { return planted_missing_helper(x) * 2; }
