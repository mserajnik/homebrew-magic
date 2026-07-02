<h1>
  <img src=".github/logo.webp" alt="" height="100">
  <br>
  homebrew-magic
</h1>

[![Lint status][badge-lint-status]][badge-lint-status-url]
[![Build status][badge-build-status]][badge-build-status-url]

> A Homebrew tap for Forge and XMage, two open-source Magic: The Gathering
> implementations

This tap packages [Forge][forge] and [XMage][xmage] into macOS apps,
distributed as Homebrew casks, offering a more convenient way to install,
update, and run these projects than the official methods. It features:

- __Forge in all three modes__: Desktop, Adventure Mode, and the Adventure
  Editor, each installed as its own app.
- __XMage client and server, as separate apps__: the client always plays on a
  server; connect to a public server to play online, or run the bundled local
  server to play locally, including against the AI.
- __Stable and snapshot channels__: Forge ships as the latest stable release or
  the rolling daily snapshot; XMage ships as its regular releases.
- __No Java prerequisite__: each app bundles its own Java runtime, so there is
  nothing to install besides the cask.

## Table of contents

- [Install](#install)
  - [Forge](#forge)
  - [XMage](#xmage)
- [Updating](#updating)
- [Notes](#notes)
  - [Forge-specific notes](#forge-specific-notes)
  - [XMage-specific notes](#xmage-specific-notes)
- [Maintainer](#maintainer)
- [Contribute](#contribute)
- [Licenses](#licenses)
- [Disclaimer](#disclaimer)

## Install

Since Homebrew 6.0.0, casks from non-official taps must be explicitly
[trusted][homebrew-tap-trust] before Homebrew loads them. Trust this tap once:

```sh
brew trust mserajnik/magic
```

> [!IMPORTANT]
> Installing a cask by its fully-qualified name trusts only that one cask,
> which is enough for XMage. Each Forge cask, however, declares
> `conflicts_with` the other, so installing either one makes Homebrew load the
> other to check the conflict, and loading a cask from an untrusted tap fails.
> Trusting the whole tap once covers all three casks.

### Forge

To install Forge, run:

```sh
brew install --cask mserajnik/magic/forge
```

This installs three apps:

- __Forge__: the original desktop rules engine.
- __Forge Adventure Mode__: the Shandalar-style single-player mode.
- __Forge Adventure Editor__: the Adventure Mode content editor.

To install the daily snapshot build instead of the stable release, use:

```sh
brew install --cask mserajnik/magic/forge@snapshot
```

> [!NOTE]
> The two Forge casks conflict; install one or the other.

### XMage

To install XMage, run:

```sh
brew install --cask mserajnik/magic/xmage
```

This installs two apps:

- __XMage__: the client. It always connects to a server: a public one to play
  online, or your local server (below) to play locally, including against the
  AI.
- __XMage Server__: the server, opened in a Terminal window so its log is
  visible and it can be stopped conveniently (by pressing
  <kbd>Ctrl</kbd>+<kbd>C</kbd>). Run it to play locally, including against the
  AI.

## Updating

The stable Forge and XMage casks track their upstream releases; the Forge
snapshot cask is rebuilt daily. Update with the usual:

```sh
brew update
brew upgrade --cask <cask-name>
```

E.g., to update Forge, run:

```sh
brew upgrade --cask forge
```

> [!NOTE]
> Older builds are not kept indefinitely; if you need a specific past version,
> build it yourself with the scripts in [`build/`](build).

## Notes

- These are Apple silicon (`arm64`) builds requiring macOS 11 (Big Sur) or
  newer; Intel Macs are not supported (GitHub's Intel macOS runners have been
  retired).
- The apps are ad-hoc signed (no paid Apple Developer account). The cask
  removes the quarantine attribute on install, so they launch normally.

### Forge-specific notes

- The built-in updater is disabled; update Forge with Homebrew (above) instead.
- On first launch the app copies its game data into
  `~/Library/Application Support/Forge` and runs from there, so every feature,
  including the Adventure Editor's saving, can write. This copy is refreshed
  automatically when you upgrade to a new Forge version, so the first launch
  after an install or upgrade takes a few extra seconds.
- User data (decks, preferences, saves, downloaded card images) lives under
  `~/Library/Application Support/Forge` and `~/Library/Caches/Forge`, and is
  preserved across upgrades.
- Plain `brew uninstall` removes the apps but leaves the game-data copy and
  your user data in `~/Library`. To remove everything, including that data:

  ```sh
  brew uninstall --zap --cask forge
  ```

### XMage-specific notes

- On first launch each app seeds its resources into its own directory under
  `~/Library/Application Support` and runs from there. The client downloads
  card images on demand; these and the card database are preserved across
  upgrades.
- XMage Server opens in a Terminal window. macOS asks to allow incoming network
  connections the first time it runs; the client connects to localhost by
  default.
- The "What's new" news page no longer pops up on launch: it needs JavaFX,
  which the bundled runtime omits, and upstream would otherwise open it in your
  browser every launch. The "Show what's new" button still opens it in your
  browser on demand. Nothing else depends on JavaFX.
- Plain `brew uninstall` removes the apps but leaves your data in `~/Library`.
  To remove everything, including the downloaded card images, card database,
  and preferences:

  ```sh
  brew uninstall --zap --cask xmage
  ```

## Maintainer

[Michael Serajnik][maintainer]

## Contribute

You are welcome to help out!

[Open an issue][issues] or [make a pull request][pull-requests].

## Licenses

- [`AGPL-3.0-or-later`][license-agpl-3.0-or-later] (Code)
- [`GPL-3.0-or-later`][license-gpl-3.0-or-later] (Forge source patches)
- [`MIT`][license-mit] (XMage source patches)
- [`CC-BY-SA-4.0`][license-cc-by-sa-4.0] (Documentation and graphic assets)
- [`CC0-1.0`][license-cc0-1.0] (Configuration files)

This project follows the [REUSE specification][reuse-spec].

## Disclaimer

This is an independent, community-made Homebrew tap for the open-source
[Forge][forge] and [XMage][xmage] projects. It is not affiliated with, endorsed
by, or sponsored by Wizards of the Coast LLC, and it is not an official Forge
or XMage project.

Forge and XMage are both implementations of Magic: The Gathering. Magic: The
Gathering, including its card data and imagery, is the property of Wizards of
the Coast. The app icons are derived from the respective project's original
artwork/logos. This tap is intended for private, non-commercial use only and
comes with no warranty.

[badge-build-status]: https://github.com/mserajnik/homebrew-magic/actions/workflows/build.yaml/badge.svg
[badge-build-status-url]: https://github.com/mserajnik/homebrew-magic/actions/workflows/build.yaml
[badge-lint-status]: https://github.com/mserajnik/homebrew-magic/actions/workflows/lint.yaml/badge.svg
[badge-lint-status-url]: https://github.com/mserajnik/homebrew-magic/actions/workflows/lint.yaml
[forge]: https://github.com/Card-Forge/forge
[homebrew-tap-trust]: https://docs.brew.sh/Tap-Trust
[issues]: https://github.com/mserajnik/homebrew-magic/issues
[license-agpl-3.0-or-later]: LICENSES/AGPL-3.0-or-later.txt
[license-cc-by-sa-4.0]: LICENSES/CC-BY-SA-4.0.txt
[license-cc0-1.0]: LICENSES/CC0-1.0.txt
[license-gpl-3.0-or-later]: LICENSES/GPL-3.0-or-later.txt
[license-mit]: LICENSES/MIT.txt
[maintainer]: https://github.com/mserajnik
[pull-requests]: https://github.com/mserajnik/homebrew-magic/pulls
[reuse-spec]: https://reuse.software/spec/
[xmage]: https://github.com/magefree/mage
