"""rooted_data: a package below the repository root whose test reads a file the build gives it (`test_data` in BUCK)."""


def shout(word: String) -> String:
    return word + String("!")
