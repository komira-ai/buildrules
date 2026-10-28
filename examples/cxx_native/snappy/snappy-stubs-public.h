// snappy's snappy-stubs-public.h as its CMake build writes it (snappy-stubs-public.h.in) for a POSIX system with <sys/uio.h>: version 1.3.1.
#ifndef THIRD_PARTY_SNAPPY_OPENSOURCE_SNAPPY_STUBS_PUBLIC_H_
#define THIRD_PARTY_SNAPPY_OPENSOURCE_SNAPPY_STUBS_PUBLIC_H_

#include <cstddef>

#include <sys/uio.h>

#define SNAPPY_MAJOR 1
#define SNAPPY_MINOR 3
#define SNAPPY_PATCHLEVEL 1
#define SNAPPY_VERSION \
    ((SNAPPY_MAJOR << 16) | (SNAPPY_MINOR << 8) | SNAPPY_PATCHLEVEL)

#endif  // THIRD_PARTY_SNAPPY_OPENSOURCE_SNAPPY_STUBS_PUBLIC_H_
