# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

cask "xmage" do
  version "1.4.60V3"
  sha256 "895aa56ce217a2660fa8462a36be131789862776db1d9a356f17e5834e6435b0"

  url "https://github.com/mserajnik/homebrew-magic/releases/download/xmage-#{version}/XMage-#{version}-arm64.dmg"
  name "XMage"
  desc "Open-source Magic: The Gathering client and server"
  homepage "https://github.com/magefree/mage"

  depends_on arch: :arm64
  depends_on macos: :big_sur

  app "XMage.app"
  app "XMage Server.app"

  # The apps are ad-hoc signed, so clear the quarantine attribute to avoid the
  # Gatekeeper prompt on first launch.
  postflight do
    ["XMage.app", "XMage Server.app"].each do |bundle|
      system_command "/usr/bin/xattr",
                     args: ["-dr", "com.apple.quarantine", "#{appdir}/#{bundle}"]
    end
  end

  # On first launch each app seeds its resources into `~/Library/Application
  # Support` and runs from there; the client also downloads card images into
  # its directory. Homebrew only removes these on `--zap`, which also removes
  # the card database, decks, and preferences. The `mage.client*.plist` entry
  # removes the preference files the client spills to the macOS Java
  # preferences store; a few values persist in the shared
  # `com.apple.java.util.prefs.plist`, which is left alone as other Java apps
  # use it too.
  zap trash: [
    "~/Library/Application Support/XMage Server",
    "~/Library/Application Support/XMage",
    "~/Library/Preferences/mage.client*.plist",
  ]

  caveats <<~EOS
    XMage Server.app opens in a Terminal window so its log is visible and it can
    be stopped; macOS will ask to allow incoming network connections the first
    time it runs. The client connects to localhost by default.
  EOS
end
