cask "firefox-password-view" do
  version "1.3.0"
  # This is CI's hash. The zip holds the Swift binary, and its LC_UUID
  # follows the macOS SDK installed on the build machine, so a local run
  # writes a different SHA-256. CI builds the asset a release uploads. Read
  # the hash from ci.yml's reproducible-build job. That job prints it on
  # every push.
  sha256 "5df86c93b89e9eef94288cdb420bf0a2361e6315e02ba6b4f56d0c5afd710c69"

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
