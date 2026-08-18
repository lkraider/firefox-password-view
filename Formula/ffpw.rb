class Ffpw < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"
  url "https://github.com/lkraider/firefox-password-view/releases/download/v1.2.0/ffpw-aarch64-macos.tar.gz"
  # This is CI's hash. A build done on a different machine produces a
  # different SHA-256. Each machine has its own macOS SDK version
  # installed, and Zig's linker hashes SDK-derived bytes into the
  # binary's UUID. CI is the machine whose build ships as the release
  # asset. Read the hash from ci.yml's reproducible-build job. That job
  # prints it on every push.
  sha256 "8aa2af400b31b710140986cedf6a394ab41a7cfc0b5e3ea80a47671b7da826fa"
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
