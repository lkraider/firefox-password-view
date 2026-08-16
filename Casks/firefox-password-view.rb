cask "firefox-password-view" do
  version "1.0.0"
  # The build is reproducible (see build.zig and scripts/package-release.sh),
  # so this was computed locally with scripts/package-release.sh ahead of
  # the actual v1.0.0 tag; ci.yml's reproducible-build job checks every
  # push that this still holds.
  sha256 "cf3e748670d11fbade1e35cf21209ef78e6f8e5b5186799dcd1920b6995a8f4a"

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
