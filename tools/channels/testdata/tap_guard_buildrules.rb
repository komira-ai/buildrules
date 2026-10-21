# The formula the Homebrew tap's path guard is to accept for buildrules 1.2.3: the renderer's output without a version line (the url carries it), with the
# checksums of tools/channels/testdata/fixtures/SHA256SUMS. The guard's template binds a tarball to `<formula>-<V>-<target>.tar.gz`, and the command
# line is shipped as `buildrules-cli-<V>-<target>.tar.gz` (the source archive owns `buildrules-<V>.tar.gz`), so THE GUARD DOES NOT ADMIT THIS FILE YET:
# it needs a per-formula asset-name map (`ASSET_STEMS = { buildrules: 'buildrules-cli' }`, used where the template and the base-version reader build a
# file name). That change is proposed in the pull request that added this file and is made in the tap, not here. When the tap has it, replace these
# comment lines with the tap commit and the fixture's path there, as the sibling tool's copy does.
# The comment lines above are not part of the file: tools/channels/channels_cli_test.zig compares everything below them with what the release
# workflow's render command writes, and tools/deploy/drivers/tap_test.zig opens its pull request from it.
class Buildrules < Formula
  desc "Hermetic Buck2 rules and toolchains"
  homepage "https://buildrules.dev"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/komira-ai/buildrules/releases/download/v1.2.3/buildrules-cli-1.2.3-macos-arm64.tar.gz"
      sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/komira-ai/buildrules/releases/download/v1.2.3/buildrules-cli-1.2.3-linux-aarch64.tar.gz"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
    on_intel do
      url "https://github.com/komira-ai/buildrules/releases/download/v1.2.3/buildrules-cli-1.2.3-linux-x86_64.tar.gz"
      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    end
  end

  def install
    bin.install "buildrules"
  end

  test do
    assert_match "buildrules #{version}", shell_output("#{bin}/buildrules --version")
  end
end
