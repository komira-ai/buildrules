"""testdata: a package whose tests read files and variables that `mojo_package(test_data = ..., test_env = ...)` gives them (BUCK)."""


def greeting(name: String) -> String:
    return String("hello, ") + name
