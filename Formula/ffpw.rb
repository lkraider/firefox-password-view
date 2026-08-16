class Ffpw < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"
  url "https://github.com/lkraider/firefox-password-view/releases/download/v1.0.0/ffpw-aarch64-macos.tar.gz"
  # This is CI's hash, not a local build's: builds on different machines
  # differ by whatever macOS SDK version each has installed (confirmed:
  # Zig's linker hashes SDK-derived bytes into the binary's UUID), and CI
  # is the machine whose build actually ships as the release asset. Read
  # from ci.yml's reproducible-build job, which prints it on every push.
  sha256 "d6546937be1c8c22f75716beded61115b8b62cb1fe0505a2c4bd13eab6935755"
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
