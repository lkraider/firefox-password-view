cask "firefox-password-view" do
  version "1.0.0"
  # TODO: replace once v1.0.0 is tagged and released; computed from the
  # release asset with `shasum -a 256 FirefoxPasswordView-1.0.0-macos.zip`.
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

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
