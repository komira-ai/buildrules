"""The pinned Postgres of the Rust test fixture (README.md): conda-forge's `postgresql` for linux-64 and every package of its run closure, each by
version, build, sha256 and size. `pg_prefix` unpacks them into one tree; `pg_run` starts the server from it for one test run.

The closure is the `depends` of `postgresql`, followed until nothing new is named, one build per name (conda-forge's index, linux-64 and noarch).
A change of version is a change of every row this list says it needs: the `depends` of the new build decide.

One package of the closure is left out: `libedit`, which only krb5's own command-line tools link (`bin/ktutil`, `bin/kadmin`: no library and no program
the server or initdb loads names it), and whose versions are dates, which this repository does not carry.
"""

POSTGRES_VERSION = "17.12"

# name -> the package. `postgresql` is the server (bin/postgres, bin/initdb); `libpq` holds its share/ and the modules initdb loads.
POSTGRES_PACKAGES = {
    "_openmp_mutex": {"version": "4.5", "build": "20_gnu", "url": "https://conda.anaconda.org/conda-forge/linux-64/_openmp_mutex-4.5-20_gnu.conda", "sha256": "1dd3fffd892081df9726d7eb7e0dea6198962ba775bd88842135a4ddb4deb3c9", "size": 28948},
    "ca-certificates": {"version": "2026.10.23", "build": "hbd8a1cb_0", "url": "https://conda.anaconda.org/conda-forge/noarch/ca-certificates-2026.10.23-hbd8a1cb_0.conda", "sha256": "95619b9c1184be7175392eeb0ee7eeb5ccf25d280951f4225f2d62e725790be3", "size": 130057},
    "cyrus-sasl": {"version": "2.1.28", "build": "hac629b4_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/cyrus-sasl-2.1.28-hac629b4_1.conda", "sha256": "7684da83306bb69686c0506fb09aa7074e1a55ade50c3a879e4e5df6eebb1009", "size": 210103},
    "icu": {"version": "78.3", "build": "h54a6638_2", "url": "https://conda.anaconda.org/conda-forge/linux-64/icu-78.3-h54a6638_2.conda", "sha256": "d7c260b7e1cf22ce04d6ba8a86eabf4e6c50bc96a5c27fe2ecb32298af3e88eb", "size": 14455340},
    "keyutils": {"version": "1.6.3", "build": "h7cc23a3_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/keyutils-1.6.3-h7cc23a3_1.conda", "sha256": "dd053c96dcb0dcfd59422aefea9d2fe937a190167f34fba7893ec1e10a7e8963", "size": 135295},
    "krb5": {"version": "1.22.2", "build": "hbc21106_2", "url": "https://conda.anaconda.org/conda-forge/linux-64/krb5-1.22.2-hbc21106_2.conda", "sha256": "2a5c38c85e63df84c4e69ee71439841ce570d259ae3060627bb9a49a938d66f4", "size": 1394333},
    "libgcc": {"version": "16.2.0", "build": "ha9f2e26_7", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
    "libgomp": {"version": "16.2.0", "build": "he0feb66_7", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgomp-16.2.0-he0feb66_7.conda", "sha256": "92a0bb350c7be6a4eedcb4e111c60aefd176018e6b1c009a6e025dbe9bbcd758", "size": 640566},
    "libiconv": {"version": "1.18", "build": "h0cb94f2_3", "url": "https://conda.anaconda.org/conda-forge/linux-64/libiconv-1.18-h0cb94f2_3.conda", "sha256": "f943117edb9cd4d9c61cc972eee5a34291dc55ea7a6e9e38da104995841cbcb6", "size": 789471},
    "liblzma": {"version": "5.8.3", "build": "hb03c661_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/liblzma-5.8.3-hb03c661_1.conda", "sha256": "9787df8c22a59c9a70d3e5a10db9ad663485e75e9ccc3f09bd092cb7b95e0dab", "size": 112995},
    "libntlm": {"version": "1.8", "build": "hb9d3cd8_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libntlm-1.8-hb9d3cd8_0.conda", "sha256": "3b3f19ced060013c2dd99d9d46403be6d319d4601814c772a3472fe2955612b0", "size": 33418},
    "libpq": {"version": "17.12", "build": "h9d76c99_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libpq-17.12-h9d76c99_0.conda", "sha256": "f17e367a493174b96fbf8b0fcecc52eaa933a21e2f2ee1b219ae75b6d54af0a7", "size": 2686425},
    "libstdcxx": {"version": "16.2.0", "build": "h934c35e_7", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
    "libxcrypt": {"version": "4.4.38", "build": "h280c20c_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libxcrypt-4.4.38-h280c20c_0.conda", "sha256": "f7e9292dd219a6435bbb1223da9586c3e70d66d169c5a92f08db3f2127df04e9", "size": 101957},
    "libxml2": {"version": "2.15.4", "build": "h7df9aa5_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/libxml2-2.15.4-h7df9aa5_1.conda", "sha256": "8c32be9e8720bc413d2b4267517459d7d71fad4a5f398a2aa8319b6d7b8a00e6", "size": 46570},
    "libxml2-16": {"version": "2.15.4", "build": "hf3af7cc_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/libxml2-16-2.15.4-hf3af7cc_1.conda", "sha256": "d1906463070c21f3215cd5de93164f31c44d5bac6ae9b5d8f5adf42b1e304039", "size": 569062},
    "libxslt": {"version": "1.1.45", "build": "h8e12856_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/libxslt-1.1.45-h8e12856_1.conda", "sha256": "3beb51b5ce8d2e0690b8517d3d955972d502cfbe2899279cbb9cbb6ff134d360", "size": 250314},
    "libzlib": {"version": "1.3.2", "build": "h25fd6f3_3", "url": "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.2-h25fd6f3_3.conda", "sha256": "eb8a0db0aa570124f7d2a93d7c7f596e3390df5e047818d873baad32985fc736", "size": 63713},
    "lz4-c": {"version": "1.11.1", "build": "hee9eb32_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/lz4-c-1.11.1-hee9eb32_0.conda", "sha256": "e66dc54f3f3547f1988dc3ef606f2790d7fde24037ffd0a19b4f58e2895f4183", "size": 237352},
    "ncurses": {"version": "6.6", "build": "hdb14827_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/ncurses-6.6-hdb14827_1.conda", "sha256": "5d46557214ed184381dafe835b7c94a474a1c3b307a08a250b1ea4779b44ffb3", "size": 911196},
    "openldap": {"version": "2.6.13", "build": "hbde042b_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/openldap-2.6.13-hbde042b_0.conda", "sha256": "21c4f6c7f41dc9bec2ea2f9c80440d9a4d45a6f2ac13243e658f10dcf1044146", "size": 786149},
    "openssl": {"version": "3.6.5", "build": "h781a0a9_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/openssl-3.6.5-h781a0a9_0.conda", "sha256": "9c1533f1cf784f0e250919c0c9762d0b0e6bc727a79290ffb7cea1ceca1d038c", "size": 3195299},
    "postgresql": {"version": "17.12", "build": "hfefc96f_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/postgresql-17.12-hfefc96f_0.conda", "sha256": "6567686133ba8a59277c4e7016a53bbac5cd276be5d6280125a3bb5c49d10b3b", "size": 5673711},
    "readline": {"version": "8.3", "build": "hd6e31c0_1", "url": "https://conda.anaconda.org/conda-forge/linux-64/readline-8.3-hd6e31c0_1.conda", "sha256": "01b3fe073a66e321970d09e04b388708f8cbdca5cdfbfcb7c9eeb470ad10383d", "size": 348899},
    "tzcode": {"version": "2026f", "build": "hebe6cf0_0", "url": "https://conda.anaconda.org/conda-forge/linux-64/tzcode-2026f-hebe6cf0_0.conda", "sha256": "6e17f0f65ee110f1dbb4375021901daf3ef9d908e9c07a3e9fcbdb3d723a848a", "size": 71537},
    "tzdata": {"version": "2026e", "build": "h5d301ff_0", "url": "https://conda.anaconda.org/conda-forge/noarch/tzdata-2026e-h5d301ff_0.conda", "sha256": "2b7ca858879f183ce2dcc65b300f48a0133d5430550f35b23d80d405a0788dbf", "size": 119208},
    "zstd": {"version": "1.5.7", "build": "hb78ec9c_7", "url": "https://conda.anaconda.org/conda-forge/linux-64/zstd-1.5.7-hb78ec9c_7.conda", "sha256": "47d682b9f6d6ec9eb1a6e6c3e75ea6273e899e78fb7fc59f81d39745009fbc60", "size": 601301},
}
