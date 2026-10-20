# Only used when this repository is mounted AS the `prelude` cell of a consumer (P1 mitigation
# experiment): the rules become globals of every BUCK file, loaded once for all cells. The
# bundled prelude is then absent, so the configuration rules come from rules/minicfg.
load("//rules/minicfg:rules.bzl", _constraint_setting = "constraint_setting", _constraint_value = "constraint_value", _platform = "platform")
load("//rules/probe:tset.bzl", _probe_node = "probe_node")

load_symbols({
    "constraint_setting": _constraint_setting,
    "constraint_value": _constraint_value,
    "platform": _platform,
    "probe_node": _probe_node,
})
