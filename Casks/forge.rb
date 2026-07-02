# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

cask "forge" do
  version "2.0.13"
  sha256 "cb3d989baa359160241564a1c2a642d0f277a06377705492d84ab01d41700293"

  url "https://github.com/mserajnik/homebrew-magic/releases/download/forge-#{version}/Forge-#{version}-arm64.dmg"
  name "Forge"
  desc "Open-source Magic: The Gathering rules engine"
  homepage "https://github.com/Card-Forge/forge"

  conflicts_with cask: "mserajnik/magic/forge@snapshot"
  depends_on arch: :arm64
  depends_on macos: :big_sur

  app "Forge.app"
  app "Forge Adventure Mode.app"
  app "Forge Adventure Editor.app"

  # The apps are ad-hoc signed, so clear the quarantine attribute to avoid the
  # Gatekeeper prompt on first launch.
  postflight do
    ["Forge.app", "Forge Adventure Mode.app", "Forge Adventure Editor.app"].each do |bundle|
      system_command "/usr/bin/xattr",
                     args: ["-dr", "com.apple.quarantine", "#{appdir}/#{bundle}"]
    end
  end

  # On first launch the app copies its game data into `~/Library/Application
  # Support/Forge` so every feature (including the Adventure Editor) can save.
  # Homebrew only removes that on `--zap`, which also removes decks, saves, and
  # preferences.
  zap trash: [
    "~/Library/Application Support/Forge",
    "~/Library/Caches/Forge",
  ]
end
