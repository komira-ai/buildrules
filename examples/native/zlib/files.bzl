# The files of zlib 1.3.1 the library is built from: the sources and the headers they include, as paths below the archive's `zlib-1.3.1/`. Nothing else of the
# archive is staged. A bump is the url, sha256 and size of the BUCK file and this list (a file the new version needs and this list lacks fails the compile).

ZLIB_SRCS = [
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "infback.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
]

ZLIB_HDRS = [
    "crc32.h",
    "deflate.h",
    "gzguts.h",
    "inffast.h",
    "inffixed.h",
    "inflate.h",
    "inftrees.h",
    "trees.h",
    "zconf.h",
    "zlib.h",
    "zutil.h",
]

ZLIB_FILES = ZLIB_SRCS + ZLIB_HDRS
