"""Downloads of kcov v42 and what it links, and of the LLVM pieces of Mojo branch coverage (linux x86_64): URL, sha256, size in bytes.

The values are the pinned `linux-x86_64` kcov rows, so a hash here is
the hash the coverage builds use: the tag's source archive of kcov (GPL-2.0, build-only: the tool runs in actions and is never
shipped) and the conda-forge packages of the static libraries it links. libgcc is rules/pins' own.
"""

KCOV_PINS = {
    "kcov_bzip2": {
        "name": "bzip2_1.0.8_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/bzip2-1.0.8-hda65f42_10.conda",
        "sha256": "1a0d382c515ebf55f8ee1f38c8b81bc95af5c2acc42ad53b66bc5df932032f96",
        "size": 257808,
    },
    "kcov_elfutils": {
        "name": "elfutils_0.194_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/elfutils-0.194-h849f50c_0.conda",
        "sha256": "f71eae7dc8ff9392d225d2d529691b2db16289b7d8009646eeb1adf0caf3937b",
        "size": 1289929,
    },
    "kcov_lzma": {
        "name": "liblzma-static_5.8.3_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/liblzma-static-5.8.3-ha02ee65_1.conda",
        "sha256": "237563ec760527207b84338807e49e817ac53c3306e566aecaa4fd4a32530b56",
        "size": 125751,
    },
    "kcov_src": {
        "name": "kcov-v42.tar.gz",
        "url": "https://github.com/SimonKagstrom/kcov/archive/refs/tags/v42.tar.gz",
        "sha256": "2c47d75397af248bc387f60cdd79180763e1f88f3dd71c94bb52478f8e74a1f8",
        "size": 259243,
    },
    "kcov_zlib": {
        "name": "zlib_1.3.2_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/zlib-1.3.2-h25fd6f3_3.conda",
        "sha256": "16080a1c7724f7d25727cdc23c7658e0cec2db52448c1dc0c33467ee2c6e1c62",
        "size": 96132,
    },
    "kcov_zstd": {
        "name": "zstd-static_1.5.7_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/zstd-static-1.5.7-hb72f32e_7.conda",
        "sha256": "62e9e4b9274c2c7028e0bcdf80c254ee95499d4860e7c13d8926485d03b0d27b",
        "size": 475941,
    },
}

# The LLVM pieces of Mojo branch coverage (rules/coverage/branch/README.md): llvm-profdata 23.1.3, libLLVM and the libraries it loads, and
# the compiler-rt 23.1.3 profile runtime, all from conda-forge. (Mojo's own lld, LLVM 24, comes from the pinned Mojo compiler package.)
# Apache-2.0 WITH LLVM-exception (LLVM, compiler-rt), MIT (libxml2), BSD-3-Clause (zstd), Zlib (libzlib), LGPL-2.1 (libiconv, loaded as a
# shared library by the tools and linked into nothing). Nothing here is packed into a release artifact: these are build tools.
LLVM_BRANCH_PINS = {
    "libiconv": {
        "name": "libiconv_1.18_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libiconv-1.18-h0cb94f2_3.conda",
        "sha256": "f943117edb9cd4d9c61cc972eee5a34291dc55ea7a6e9e38da104995841cbcb6",
        "size": 789471,
    },
    "libllvm": {
        "name": "libllvm23_23.1.3_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libllvm23-23.1.3-h474f4eb_0.conda",
        "sha256": "7ce347e2da1502442d4df406101cfaf429927b7a9410badadd3f147d3cbf2d00",
        "size": 45082185,
    },
    "libxml2": {
        "name": "libxml2-16_2.15.4_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libxml2-16-2.15.4-hbdfff7e_0.conda",
        "sha256": "b6f96287c408269f5067bb4f7a61693ff5c856152902362964d9807152b9c146",
        "size": 565717,
    },
    "libzlib": {
        "name": "libzlib_1.3.1_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.1-hb9d3cd8_2.conda",
        "sha256": "d4bfe88d7cb447768e31650f06257995601f89076080e76df55e3112d4e47dc4",
        "size": 60963,
    },
    "rt": {
        "name": "compiler-rt23_linux-64_23.1.3_noarch.conda",
        "url": "https://conda.anaconda.org/conda-forge/noarch/compiler-rt23_linux-64-23.1.3-h0e38de2_0.conda",
        "sha256": "7a044f184a5ed44fb905882c25ba950ec7a5b53c8f46ad40cba5c1a079d8d6a3",
        "size": 46990831,
    },
    "tools": {
        "name": "llvm-tools-23_23.1.3_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/llvm-tools-23-23.1.3-h7399f5f_0.conda",
        "sha256": "2d948bde496207d44846b580ab683157305860edadf3dec1a6860073bfd1b837",
        "size": 25434792,
    },
    "zstd": {
        "name": "zstd_1.5.7_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/zstd-1.5.7-hb78ec9c_7.conda",
        "sha256": "47d682b9f6d6ec9eb1a6e6c3e75ea6273e899e78fb7fc59f81d39745009fbc60",
        "size": 601301,
    },
}
