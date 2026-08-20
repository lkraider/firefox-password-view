class Keywise < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/keywise"
  url "https://github.com/lkraider/keywise/releases/download/v2.0.0/keywise-aarch64-macos.tar.gz"
  # scripts/release-package.sh writes this tarball byte for byte on any
  # macOS host, so a local run reproduces this hash. docs/REPRODUCIBLE.md
  # names the settings. ci.yml's reproducible-build job prints it on every
  # push, and release.yml compares it with the asset it uploads.
  sha256 "c4d4fbf4ae70888ac6cc0a510eb861beaf4cf8702c320e0d18ec57608a4c1d68"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "keywise"
  end

  test do
    assert_path_exists bin/"keywise"
    assert_predicate bin/"keywise", :executable?
  end
end
