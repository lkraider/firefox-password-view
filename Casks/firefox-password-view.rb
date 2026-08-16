cask "firefox-password-view" do
  version "1.0.0"
  # This is CI's hash, not a local build's: builds on different machines
  # differ by whatever macOS SDK version each has installed (confirmed:
  # Zig's linker hashes SDK-derived bytes into the binary's UUID), and CI
  # is the machine whose build actually ships as the release asset. Read
  # from ci.yml's reproducible-build job, which prints it on every push.
  sha256 "f03a4b2d13962d6818a768a421663f6655ea7bd286dd789a772bc38a40cb8bf4"

  url "https://github.com/lkraider/firefox-password-view/releases/download/v#{version}/FirefoxPasswordView-#{version}-macos.zip"
  name "Firefox Password View"
  desc "Views a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "FirefoxPasswordView.app"

  zap trash: "~/Library/Preferences/br.com.nkey.FirefoxPasswordView.plist"

  # Ad-hoc signed, not notarized: no Apple Developer ID exists for this
  # project. Gatekeeper blocks a first launch as "from an unidentified
  # developer" without this.
  caveats do
    <<~EOS
      This app is ad-hoc signed, not notarized. On first launch, either:
        - right-click the app in Finder and choose Open, or
        - remove the quarantine attribute yourself:
          xattr -cr "#{appdir}/FirefoxPasswordView.app"
    EOS
  end
end
