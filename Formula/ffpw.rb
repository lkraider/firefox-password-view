class Ffpw < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"
  url "https://github.com/lkraider/firefox-password-view/releases/download/v1.0.0/ffpw-aarch64-macos.tar.gz"
  # TODO: replace once v1.0.0 is tagged and released; computed from the
  # release asset with `shasum -a 256 ffpw-aarch64-macos.tar.gz`.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
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
