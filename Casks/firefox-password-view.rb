cask "firefox-password-view" do
  version "1.0.0"
  # This is CI's hash. A build done on a different machine produces a
  # different SHA-256. Each machine has its own macOS SDK version
  # installed, and Zig's linker hashes SDK-derived bytes into the
  # binary's UUID. CI is the machine whose build ships as the release
  # asset. Read the hash from ci.yml's reproducible-build job. That job
  # prints it on every push.
  sha256 "f03a4b2d13962d6818a768a421663f6655ea7bd286dd789a772bc38a40cb8bf4"

  url "https://github.com/lkraider/firefox-password-view/releases/download/v#{version}/FirefoxPasswordView-#{version}-macos.zip"
  name "Firefox Password View"
  desc "Views a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/firefox-password-view"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "FirefoxPasswordView.app"

  zap trash: "~/Library/Preferences/br.com.nkey.FirefoxPasswordView.plist"

  # The app is ad-hoc signed. This project has no Apple Developer ID, so
  # it is not notarized. Gatekeeper otherwise blocks a first launch as
  # coming from an unidentified developer.
  caveats do
    <<~EOS
      This app is ad-hoc signed. It is not notarized. On first launch, either:
        - right-click the app in Finder and choose Open, or
        - remove the quarantine attribute yourself:
          xattr -cr "#{appdir}/FirefoxPasswordView.app"
    EOS
  end
end
