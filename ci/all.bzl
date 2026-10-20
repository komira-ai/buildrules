# What //ci:all covers, and what it deliberately does not. Read by ci/completeness.bxl, which fails when a target of the tree is neither
# built by //ci:all (or //ci:mojo) nor listed here. Every entry is a target pattern and the one-line reason it is not built.

# Targets that are red on purpose or are not built by a wildcard build. A key is a target expression and must match at least one target.
# Each package's scrub_files is not excluded: the scrub reads a fixture's text like any other file's.
EXCLUDED = {
    "//examples/p4ws/crates/probe_env/... - //examples/p4ws/crates/probe_env:scrub_files": "refusal fixture: the build script is refused by design (a hidden input through the environment)",
    "//examples/p4ws/crates/probe_tree/... - //examples/p4ws/crates/probe_tree:scrub_files": "refusal fixture: the build script is refused by design (it reads outside its declared tree)",
    "//examples/p4ws/crates/probe_usr/... - //examples/p4ws/crates/probe_usr:scrub_files": "refusal fixture: the build script is refused by design (it reads the host's /usr)",
    "//examples/mojo/registry/cnative:coverage": "refusal fixture: a package with no test has no coverage to measure, and the rule refuses",
    "crates//crates/zdemo:coverage": "refusal: Rust coverage is not implemented, so the target is incompatible with every platform; a wildcard build skips it, and a target that depends on it is refused",
    "//ci/negative/... - //ci/negative:scrub_files": "planted defect, red by design on the one platform it is compatible with; a wildcard build skips it as incompatible",
}

# Built by //ci:mojo and not by //ci:all: the public runner has no mirror for the Mojo packages (docs/contract.md, section 14). Their
# coverage is checked against //ci:mojo instead.
MIRROR_ONLY = "//ci:mojo"

# Rule kinds that describe a configuration and build nothing.
NOT_BUILT_KINDS = "constraint_setting|constraint_value|config_setting|platform|_exec_platforms"
