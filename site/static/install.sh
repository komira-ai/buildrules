#!/bin/sh
# buildrules installer: https://buildrules.dev/install.sh
#
#   curl -fsSL https://buildrules.dev/install.sh | sh
#   curl -fsSL https://buildrules.dev/install.sh | sh -s -- --version 0.0.3 --prefix /opt/buildrules --verify
#
# Downloads the buildrules command line for this machine from the GitHub releases of the project, checks its sha256 against the
# release's SHA256SUMS, and installs it as <prefix>/bin/buildrules (default prefix ~/.buildrules). It needs no root, edits no shell
# startup file, and stops without installing anything if a check fails. It installs the command line only: the rules themselves run
# on a Linux x86_64 farm or machine (see the How page).
#
#   --version V       install this version (1.2.3 or v1.2.3) instead of the latest
#   --prefix DIR      install under DIR instead of ~/.buildrules (the program is DIR/bin/buildrules)
#   --verify          also check the release's keyless signature of the tarball with cosign; it stops if cosign is not installed
#   --releases-url U  read releases from U (a mirror, or a test) instead of
#                     https://github.com/komira-ai/buildrules/releases
#   -h, --help        print this text
#
# The sha256 check proves the tarball is the one SHA256SUMS lists, from the same place. --verify proves the tarball was signed by the
# release workflow of the project on refs/heads/main (cosign verify-blob with its bundle <tarball>.sigstore.json). To check a download
# by hand, or with the GitHub attestation, see RELEASING.md. macOS programs are not yet code-signed or notarised by Apple.
#
# Needs curl, tar, awk, mktemp and sha256sum or shasum. Linux (x86_64, aarch64; static programs) and macOS (arm64; there is no
# release for Intel Macs).
set -eu

releases=https://github.com/komira-ai/buildrules/releases
signer=https://github.com/komira-ai/buildrules/.github/workflows/release.yml@refs/heads/main
issuer=https://token.actions.githubusercontent.com
prefix=
want_version=
verify=0

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

usage() {
    echo "usage: install.sh [--version V] [--prefix DIR] [--verify] [--releases-url URL]"
    echo "  --version V       install this version (1.2.3 or v1.2.3); default: the latest release"
    echo "  --prefix DIR      install DIR/bin/buildrules; default: ~/.buildrules"
    echo "  --verify          check the keyless signature of the tarball with cosign (cosign must be installed)"
    echo "  --releases-url U  read releases from U instead of $releases"
    echo "  -h, --help        print this text"
}

while [ $# -gt 0 ]; do
    case $1 in
        --prefix|--version|--releases-url)
            [ $# -ge 2 ] || die "$1 needs a value (see --help)"
            case $2 in
                ""|-*) die "$1 needs a value, not '$2' (see --help)" ;;
            esac
            case $1 in
                --prefix) prefix=$2 ;;
                --version) want_version=$2 ;;
                --releases-url) releases=$2 ;;
            esac
            shift 2
            ;;
        --verify) verify=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

# The platform, as the release files name it.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) target=linux-x86_64 ;;
    Linux-aarch64|Linux-arm64) target=linux-aarch64 ;;
    Darwin-arm64) target=macos-arm64 ;;
    Darwin-x86_64) die "no buildrules release for Intel Macs (Darwin x86_64); buildrules is released for Apple silicon Macs (arm64) and for Linux on x86_64 and arm64. On an Apple silicon Mac, run this from a native shell, not one running under Rosetta" ;;
    *) die "no buildrules release for $(uname -s) $(uname -m); there are releases for Linux on x86_64 and arm64 and for macOS on arm64" ;;
esac

if [ -z "$prefix" ]; then
    prefix=${HOME:?HOME is not set; use --prefix}/.buildrules
fi

if [ -n "$want_version" ]; then
    tag=v${want_version#v}
    case "$tag" in
        v[0-9]*) ;;
        *) die "'$want_version' is not a version" ;;
    esac
    case "$tag" in
        *[!0-9A-Za-z.+_-]*) die "'$tag' is not a version" ;;
    esac
fi

for tool in curl tar awk mktemp; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but was not found"
done
if command -v sha256sum >/dev/null 2>&1; then
    sum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
    sum_tool=shasum
else
    die "sha256sum or shasum is required to check the download"
fi
if [ "$verify" = 1 ]; then
    command -v cosign >/dev/null 2>&1 || die "--verify needs cosign, which was not found; install it (https://docs.sigstore.dev) or leave --verify out"
fi

# The version: --version, else the tag that <releases>/latest redirects to.
if [ -z "$want_version" ]; then
    url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases/latest") ||
        die "could not look up the latest release at $releases/latest"
    tag=${url##*/}
    case "$tag" in
        v[0-9]*) ;;
        *) die "no buildrules release found (got '$tag'); name one with --version" ;;
    esac
    case "$tag" in
        *[!0-9A-Za-z.+_-]*) die "'$tag' is not a version" ;;
    esac
fi
version=${tag#v}
name=buildrules-cli-$version-$target
asset=$name.tar.gz

tmp=$(mktemp -d "${TMPDIR:-/tmp}/buildrules-install.XXXXXX") || die "could not make a temporary directory"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Installing buildrules $version ($target)"
curl -fsSL --retry 3 -o "$tmp/$asset" "$releases/download/$tag/$asset" ||
    die "could not download $releases/download/$tag/$asset"
curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$releases/download/$tag/SHA256SUMS" ||
    die "could not download $releases/download/$tag/SHA256SUMS"

# The sha256 the release lists for this file: exactly one 64-digit hex entry.
want=$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
case "$want" in
    ""|*[!0-9a-f]*) die "SHA256SUMS does not list $asset exactly once" ;;
esac
[ "${#want}" -eq 64 ] || die "SHA256SUMS has a malformed entry for $asset"

if [ "$sum_tool" = sha256sum ]; then
    got=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
else
    got=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
fi
[ "$got" = "$want" ] || die "sha256 mismatch for $asset: got $got, SHA256SUMS says $want; nothing was installed"

if [ "$verify" = 1 ]; then
    curl -fsSL --retry 3 -o "$tmp/$asset.sigstore.json" "$releases/download/$tag/$asset.sigstore.json" ||
        die "could not download $releases/download/$tag/$asset.sigstore.json"
    cosign_out=$(cosign verify-blob --bundle "$tmp/$asset.sigstore.json" --certificate-identity "$signer" --certificate-oidc-issuer "$issuer" "$tmp/$asset" 2>&1) ||
        die "cosign did not verify the signature of $asset: $cosign_out; nothing was installed"
    echo "Verified the signature of $asset"
fi

mkdir "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x" || die "could not unpack $asset"
[ -f "$tmp/x/$name/buildrules" ] || die "$asset does not contain $name/buildrules"

mkdir -p "$prefix/bin"
cp "$tmp/x/$name/buildrules" "$prefix/bin/.buildrules.new.$$"
chmod 755 "$prefix/bin/.buildrules.new.$$"
if [ "$("$prefix/bin/.buildrules.new.$$" --version 2>/dev/null)" != "buildrules $version" ]; then
    rm -f "$prefix/bin/.buildrules.new.$$"
    die "the downloaded program did not report 'buildrules $version'; nothing was installed"
fi
mv -f "$prefix/bin/.buildrules.new.$$" "$prefix/bin/buildrules"

echo "Installed $prefix/bin/buildrules"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *)
        echo "Add it to your PATH (put this line in your shell's startup file):"
        echo "  export PATH=\"$prefix/bin:\$PATH\""
        ;;
esac
