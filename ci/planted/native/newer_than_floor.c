/* PLANTED DEFECT: calls a C library function that glibc 2.34 does not have (arc4random came with 2.36). */
unsigned arc4random(void);

unsigned planted_native_random(void) { return arc4random(); }
