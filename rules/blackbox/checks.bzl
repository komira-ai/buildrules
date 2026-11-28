"""The checks of `blackbox_test` (defs.bzl): pure functions of plain values. Each takes `refuse`, `fail` in the rule; a test passes a recorder
(rules/rust/refusal.bzl), so every refusal is held by a target that is green when the check refuses and red when it accepts what it must refuse."""

_HEX = "0123456789abcdef"

def _is_sha256(text):
    return len(text) == 64 and all([c in _HEX for c in text.elems()])

def check_image(who, image, refuse = fail):
    """`image` names a container image by its digest: `[docker://]<repository>@sha256:<64 lower-case hex>`. A tag (`:latest`, `:24.04`), alone or beside
    the digest, is refused: a tag moves, and the farm and docker would then run what the tag says that day."""
    ref = image[len("docker://"):] if image.startswith("docker://") else image
    if "@" not in ref:
        refuse("{}: `image` {} has no digest: name the image as `<repository>@sha256:<64 hex digits>` (a tag is not accepted)".format(who, repr(image)))
        return
    repo, digest = ref.split("@", 1)
    if not digest.startswith("sha256:") or not _is_sha256(digest[len("sha256:"):]):
        refuse("{}: `image` {}: the digest must be `sha256:` and 64 lower-case hex digits".format(who, repr(image)))
    if not repo or repo.endswith("/") or repo.startswith("/"):
        refuse("{}: `image` {} names no repository before its digest".format(who, repr(image)))
    elif ":" in repo.split("/")[-1]:
        refuse("{}: `image` {} has a tag (`{}`): name the image by its digest alone".format(who, repr(image), repo.split("/")[-1].split(":", 1)[1]))

def check_pin(who, what, url, sha256, size, refuse = fail):
    """A package is pinned by its URL, its sha256 (64 lower-case hex digits) and its length (a positive number of bytes); `what` says where the values came
    from (the `package` attribute, or the `-c` keys of a candidate)."""
    if not url.strip():
        refuse("{}: {}: the url is empty".format(who, what))
    elif not url.startswith("https://"):
        refuse("{}: {}: the url {} is not https".format(who, what, repr(url)))
    if not _is_sha256(sha256):
        refuse("{}: {}: the sha256 must be 64 lower-case hex digits, got {}".format(who, what, repr(sha256)))
    if type(size) != "int" or size <= 0:
        refuse("{}: {}: the size must be the package's positive length in bytes, got {}".format(who, what, repr(size)))

def candidate_keys(candidate):
    """The `[blackbox]` keys a caller passes the candidate package by (`-c blackbox.<candidate>_url=...`): url, sha256, size."""
    return [candidate + "_url", candidate + "_sha256", candidate + "_size"]

def check_candidate(who, candidate, values, refuse = fail):
    """`values`: the three `[blackbox]` values of `candidate_keys(candidate)`, as the configuration holds them ("" when absent). None set: the package is
    the pinned one. Some set: all three must be, and pin the package as `check_pin` says; a key set to an empty value is refused (an orchestrator that
    lost its value must not test the pinned release in its place). Returns the pin (url, sha256, size) or None."""
    if not candidate or any([c not in "abcdefghijklmnopqrstuvwxyz0123456789_" for c in candidate.elems()]):
        refuse("{}: `candidate` {} is not a name of lower-case letters, digits and `_`".format(who, repr(candidate)))
        return None
    keys = candidate_keys(candidate)
    given = [k for k, v in zip(keys, values) if v != None]
    if not given:
        return None
    missing = [k for k, v in zip(keys, values) if v == None or not v.strip()]
    if missing:
        refuse("{}: the candidate package is passed by `-c blackbox.<key>=...` with all of {} set and not empty: {} {} not".format(
            who,
            ", ".join(keys),
            ", ".join(missing),
            "is" if len(missing) == 1 else "are",
        ))
        return None
    url, sha256, size_text = [v.strip() for v in values]
    size = int(size_text) if size_text.isdigit() else -1
    check_pin(who, "the candidate package (`-c blackbox.{}_*`)".format(candidate), url, sha256, size, refuse = refuse)
    return struct(url = url, sha256 = sha256, size = size)

# The names the flags may say: `{addr:<name>}` and `{port:<name>}` of a fake or `service`, `{root}` (the unpacked package) and `{work}` (the run's own
# directory). `{{` is a `{`.
_WORDS = ["root", "work"]

def placeholders(text):
    """The placeholders of `text` in order (`addr:x`, `port:x`, `root`, `work`, or what an unknown one says), or None when a `{` is not closed."""
    out = []
    rest = text
    for _ in range(len(text)):
        at = rest.find("{")
        if at < 0:
            return out
        if rest[at + 1:at + 2] == "{":
            rest = rest[at + 2:]
            continue
        end = rest.find("}", at)
        if end < 0:
            return None
        out.append(rest[at + 1:end])
        rest = rest[end + 1:]
    return out

def check_flags(who, what, flags, names, refuse = fail):
    """Every placeholder of `flags` (the flags of `what`) names a process the run has (`names`: the fakes and `service`) or is `{root}` or `{work}`."""
    for flag in flags:
        found = placeholders(flag)
        if found == None:
            refuse("{}: a flag of {}, {}, opens a `{{` it does not close (`{{{{` is a `{{`)".format(who, what, repr(flag)))
            continue
        for p in found:
            if p in _WORDS:
                continue
            kind, _, name = p.partition(":")
            if kind not in ("addr", "port") or not name:
                refuse("{}: a flag of {}, {}, says `{{{}}}`: the placeholders are {{addr:<name>}}, {{port:<name>}}, {{root}} and {{work}}".format(who, what, repr(flag), p))
            elif name not in names:
                refuse("{}: a flag of {}, {}, names `{}`, which is not one of {}".format(who, what, repr(flag), name, ", ".join(sorted(names))))

def check_names(who, fakes, refuse = fail):
    """A fake is named by lower-case letters, digits, `_` and `-`, and `service` is the service's own name."""
    for name in fakes:
        if name == "service":
            refuse("{}: a fake is named `service`, the name of the service itself".format(who))
        elif not name or any([c not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for c in name.elems()]):
            refuse("{}: the fake {} is not named by lower-case letters, digits, `_` and `-`".format(who, repr(name)))

def check_service(who, service, refuse = fail):
    """`service` is the path of the service's program inside the package, relative (`usr/bin/<name>`), with no `.` or `..` component."""
    parts = service.split("/")
    if not service or service.startswith("/") or any([p in ("", ".", "..") for p in parts]):
        refuse("{}: `service` {} must be the program's path inside the package, such as `usr/bin/<name>`, with no empty, `.` or `..` part".format(who, repr(service)))

def executor_properties(base, image):
    """The property set a blackbox test is sent to the farm with: the workers' own (`base`, which the test's executor replaces whole, so every key of it
    is repeated) with `container-image` set to the test's image."""
    props = dict(base)
    props["container-image"] = image if image.startswith("docker://") else "docker://" + image
    return props
