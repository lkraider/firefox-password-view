class Ffpw < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"
  url "https://github.com/lkraider/firefox-password-view/releases/download/v1.0.0/ffpw-aarch64-macos.tar.gz"
  # The build is reproducible (see build.zig and scripts/package-release.sh),
  # so this was computed locally with scripts/package-release.sh ahead of
  # the actual v1.0.0 tag; ci.yml's reproducible-build job checks every
  # push that this still holds.
  sha256 "f61c415df298acd86d216aef0e37e266553bd638509e3dd6f402f901ce09b11d"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "ffpw"
  end

  test do
    assert_path_exists bin/"ffpw"
    assert_predicate bin/"ffpw", :executable?
  end
end
