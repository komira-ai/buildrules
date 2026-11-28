"""What ci/blackbox_candidate.bxl holds: the package a `blackbox_test` runs, read from its test command and its download, for each state of the
configuration. A pure function of what the analysis gives, so the bxl only prints."""

_TARGET = "//ci/blackbox_candidate:released_package"
_DOWNLOAD = "//ci/blackbox_candidate:released_package.package0"

_PINS = {
    # The pin of the BUCK file.
    "absent": struct(
        url = "https://github.com/komira-ai/buildrules/releases/download/v0.0.85/buildrules_0.0.85_amd64.deb",
        sha256 = "ad6f920216588ed6f4cc58c9c684d77683a18c7f669ae2cf7d0dd79d6018f2f7",
        size = 995196,
    ),
    # The candidate of ci/blackbox_candidate.buckconfig.
    "given": struct(
        url = "https://github.com/komira-ai/buildrules/releases/download/v0.0.86/buildrules_0.0.86_amd64.deb",
        sha256 = "fa0da6e10aa6ffc0a9424942c909d8eb0d3d28aa60d5971e29710a5aa7f7a7d1",
        size = 995192,
    ),
}

def selection_problems(state, command, url):
    """The problems of a test whose command is `command` and whose download is of `url`, in `state`: it must name that state's sha256 and size, and not
    the other state's, and download that state's url."""
    want = _PINS[state]
    other = _PINS["given" if state == "absent" else "absent"]
    problems = []
    if "--sha256, {}, --size, {}".format(want.sha256, want.size) not in command and '"--sha256", "{}", "--size", "{}"'.format(want.sha256, want.size) not in command:
        problems.append("the test command does not check the {} package (sha256 {}, {} bytes): {}".format(state, want.sha256, want.size, command))
    if other.sha256 in command:
        problems.append("the test command names the sha256 of the other package, {}".format(other.sha256))
    if url != want.url:
        problems.append("the package is downloaded from {}, not {}".format(url, want.url))
    return problems

def candidate_problems(ctx, state):
    node = ctx.configured_targets(_TARGET)
    info = ctx.analysis(node).providers()[ExternalRunnerTestInfo]
    download = ctx.configured_targets(_DOWNLOAD)
    url = str(download.attrs_eager().url).strip("\"")
    return selection_problems(state, str(info.command[0]), url)
