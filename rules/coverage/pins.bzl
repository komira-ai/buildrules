"""Downloads of kcov v42 and what it links (linux x86_64): URL, sha256, size in bytes.

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
