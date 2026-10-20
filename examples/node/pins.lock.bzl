# The pinned downloads of package-lock.json, in the format `kpin lock` writes (rules/kpin).
# Written by hand for this example from tslib 2.8.1's tarball: the sha256 and size of the .tgz,
# and the registry's sha512 integrity (which the unpack checks again).

KPIN_LOCK_VERSION = 1

PINS = {}

NPM = {
    "tslib@2.8.1": {
        "name": "tslib",
        "version": "2.8.1",
        "url": "https://registry.npmjs.org/tslib/-/tslib-2.8.1.tgz",
        "sri512": "sha512-oJFu94HQb+KVduSUQL7wnpmqnfmLsOA/nAh6b6EH0wCEoK0/mPeXU6c3wKDV83MkOuHPRHtSXKKU99IBazS/2w==",
        "sha256": "66f635d5eeabae44807534976913a102cf615b9a045368359c9f79ae6ee2119e",
        "size": 18477,
    },
}
