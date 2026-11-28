"""A `[blackbox]` configuration as a table, for the cases of the candidate keys (`blackbox_package(config = ...)`)."""

def config_of(table):
    """A reader of `[blackbox] <key>` that answers from `table` (None for a key it does not hold, as `read_root_config` does)."""
    return lambda key: table.get(key)
