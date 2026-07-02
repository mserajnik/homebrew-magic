#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Builds the macOS Forge app bundles and a distributable disk image from an
# upstream Forge release.
#
# The upstream `tar.bz2` distribution (game resources plus the three fat jars
# for Classic, Adventure Mode, and the Adventure Editor) is downloaded and
# packaged with jpackage into a single `Forge.app` that bundles a Java runtime.
# Classic is the main launcher; Adventure Mode and the Adventure Editor are
# added as extra jpackage launchers that share the one runtime. Two thin
# sibling bundles, `Forge Adventure Mode.app` and `Forge Adventure Editor.app`,
# exec into those extra launchers so each mode gets its own Dock and Spotlight
# icon. Everything is ad-hoc signed and wrapped into a `.dmg`, and its SHA-256
# is reported for the cask.
#
# Forge stores user data under `~/Library`, so the read-only app bundle is
# fine.
#
# Usage:
#   build-forge.sh --version <version> --url <archive-url> [options]
#
# Environment:
#   JAVA_HOME         JDK (jpackage, javac, jar) to build with; falls back to
#                     `$PATH`.
#   MAGICK            ImageMagick CLI for icon generation (default: `magick`).
#   VENDOR            jpackage vendor name (default: `Michael Serajnik`).
#   BUNDLE_ID_PREFIX  Reverse-DNS bundle-ID prefix (default: `at.mser`).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/lib.sh"

BUNDLE_ID="${BUNDLE_ID_PREFIX:-at.mser}.forge"
VENDOR="${VENDOR:-Michael Serajnik}"
HEAP="-Xmx4096m"
MAGICK="${MAGICK:-magick}"
RAW_BASE="https://raw.githubusercontent.com/Card-Forge/forge"

# Composes a smoothly scaled foreground glyph, trimmed and resized to fit `box`
# pixels, centered on the shared background, into a `.icns`.
compose_smooth() {
  local fg="$1" box="$2" icns="$3"
  # Fuzz the trim so a faint alpha halo around the glyph does not defeat it.
  "$MAGICK" "$fg" -fuzz 10% -trim +repage -resize "${box}x${box}" "$icon_work/fg.png"
  "$MAGICK" "$icon_work/bg.png" "$icon_work/fg.png" \
    -gravity center -compose over -composite "PNG32:$icon_work/icon.png"
  png_to_icns "$icon_work/icon.png" "$icns" "$icon_work"
}

# Composes pixel-art artwork onto the background using nearest-neighbor integer
# scaling: the trimmed art is enlarged by the whole-number factor that brings
# it closest to `target` pixels, so individual pixels stay crisp (no
# interpolation artifacts), then centered on the background.
compose_pixel() {
  local fg="$1" target="$2" icns="$3"
  "$MAGICK" "$fg" -trim +repage "$icon_work/fg-trim.png"
  local w factor
  w="$("$MAGICK" identify -format '%w' "$icon_work/fg-trim.png")"
  factor=$(((target + w / 2) / w))
  ((factor < 1)) && factor=1
  "$MAGICK" "$icon_work/fg-trim.png" -filter point -resize "$((factor * 100))%" \
    "$icon_work/fg.png"
  "$MAGICK" "$icon_work/bg.png" "$icon_work/fg.png" \
    -gravity center -compose over -composite "PNG32:$icon_work/icon.png"
  png_to_icns "$icon_work/icon.png" "$icns" "$icon_work"
}

# Extracts the largest frame of a multi-resolution `.ico` as a PNG.
ico_largest_frame() {
  local ico="$1" dest="$2"
  local frames="$icon_work/frames"
  rm -rf "$frames"
  mkdir -p "$frames"
  "$MAGICK" "$ico" +adjoin "$frames/frame-%02d.png"
  local biggest
  biggest="$("$MAGICK" identify -format '%w %i\n' "$frames"/frame-*.png | sort -n | tail -1 | cut -d' ' -f2-)"
  cp "$biggest" "$dest"
}

# Replaces a jpackage launcher with a wrapper that runs Forge from a writable
# copy of its game data, isolates the launcher to its own fat jar, and sets its
# Dock name and icon. The wrapper copies the bundle's read-only `res/` into the
# user's writable Forge data directory (refreshing it when the version changes)
# and runs from there, so every feature, including the Adventure Editor's save,
# can write. Forge resolves `res/` relative to the working directory.
process_launcher() {
  local name="$1" dock_name="$2" icns="$3"
  local macos="$app/Contents/MacOS"
  local app_dir="$app/Contents/app"
  local cfg="$app_dir/$name.cfg"
  local mainjar
  mainjar="$(grep -m1 '^app\.mainjar=' "$cfg" | cut -d= -f2-)"
  {
    awk -v cp="app.classpath=$mainjar" '
      /^app\.classpath=/ { next }
      { print }
      /^app\.mainjar=/ { print cp }
    ' "$cfg"
    printf 'java-options=-Xdock:name=%s\n' "$dock_name"
    # `$APPDIR` is a jpackage runtime token, substituted by the native
    # launcher.
    # shellcheck disable=SC2016
    printf 'java-options=-Xdock:icon=$APPDIR/../Resources/%s\n' "$icns"
  } >"$cfg.new"
  mv "$cfg.new" "$cfg"

  rename_launcher "$app" "$name"
  cat >"$macos/$name" <<'WRAP'
#!/bin/sh

# Run Forge from a writable copy of its game data so every feature (including
# the Adventure Editor) can save. The bundle ships `res/` read-only; mirror it
# into the user's Forge data directory, refreshing on a version change. For
# Adventure Mode the `disable-adventure-chdir` patch keeps this working
# directory; LWJGL would otherwise change it to the bundle's read-only
# `Contents/Resources/`.

set -e

here="$(cd "$(dirname "$0")" && pwd)"
appdir="$here/../app"
workdir="$HOME/Library/Application Support/Forge"
stamp="$workdir/.res-version"
res_version="__RES_VERSION__"
lock="$workdir/.res-lock"

needs_copy() {
  [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$res_version" ]
}

copy_res() {
  tmp="$workdir/.res-new.$$"
  rm -rf "$tmp"
  /usr/bin/ditto "$appdir/res" "$tmp"
  rm -rf "$workdir/res"
  mv "$tmp" "$workdir/res"
  printf '%s' "$res_version" >"$stamp"
}

if needs_copy; then
  mkdir -p "$workdir"
  # Serialize the copy across apps launched at once: the winner copies while
  # the others wait for it rather than racing the `rm` / `mv`. A lock is
  # reclaimed only after it is older than five minutes, so a crashed copy
  # eventually clears without a lock that is still in use being removed
  # mid-copy.
  while needs_copy; do
    if mkdir "$lock" 2>/dev/null; then
      if needs_copy; then copy_res; fi
      rmdir "$lock" 2>/dev/null || true
      break
    fi
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rm -rf "$lock"
    else
      sleep 1
    fi
  done
fi

cd "$workdir"
exec "$here/__LAUNCHER__-bin" "$@"
WRAP
  sed -i '' "s|__LAUNCHER__|$name|; s|__RES_VERSION__|$version|" "$macos/$name"
  chmod +x "$macos/$name"
}

# Creates a thin sibling `.app` that execs an extra launcher inside
# `Forge.app`, giving the mode its own Dock and Spotlight icon. The stub
# resolves `Forge.app` relative to its own bundle, so any cask `appdir` works;
# the cask strips the quarantine attribute on install, so the bundle is never
# translocated and the relative path holds.
make_sibling() {
  local app_name="$1" launcher="$2" identifier="$3" icns="$4"
  local bundle="$app_out/$app_name.app"
  local exe="forge-launcher"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cp "$icns" "$bundle/Contents/Resources/icon.icns"
  cat >"$bundle/Contents/MacOS/$exe" <<EOF
#!/bin/sh

appdir="\$(cd "\$(dirname "\$0")/../../.." && pwd)"
exec "\$appdir/Forge.app/Contents/MacOS/$launcher" "\$@"
EOF
  chmod +x "$bundle/Contents/MacOS/$exe"
  cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundleDisplayName</key><string>$app_name</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundleIdentifier</key><string>$identifier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$app_version</string>
  <key>CFBundleVersion</key><string>$app_version</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
}

version=""
url=""
archive=""
out_dir="./dist"
channel=""
ref="master"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="$2"
      shift 2
      ;;
    --ref)
      ref="$2"
      shift 2
      ;;
    --url)
      url="$2"
      shift 2
      ;;
    --archive)
      archive="$2"
      shift 2
      ;;
    --out)
      out_dir="$2"
      shift 2
      ;;
    --channel)
      channel="$2"
      shift 2
      ;;
    *)
      fail "Unknown argument: $1."
      ;;
  esac
done

[[ -n "$version" ]] || fail 'Missing --version.'
[[ -n "$url" || -n "$archive" ]] || fail 'Missing --url or --archive.'

assert_safe_version "$version"
app_version="$(numeric_app_version "$version")"

require_arm64

jpackage_bin="$(jdk_tool jpackage)"
javac_bin="$(jdk_tool javac)"
jar_bin="$(jdk_tool jar)"

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work_dir="$(mktemp -d)"
trap '[ -n "${smoke_pid:-}" ] && kill -9 "$smoke_pid" 2>/dev/null || true; rm -rf "$work_dir"' EXIT INT TERM

# Extra JVM modules Adventure Mode needs opened for its reflective access.
add_opens=(
  java.base/java.lang
  java.base/java.lang.reflect
  java.base/java.math
  java.base/java.net
  java.base/java.nio
  java.base/java.text
  java.base/java.util
  java.base/java.util.concurrent
  java.base/jdk.internal.misc
  java.base/sun.nio.ch
  java.desktop/java.awt
  java.desktop/java.awt.color
  java.desktop/java.awt.font
  java.desktop/java.awt.image
  java.desktop/java.beans
  java.desktop/javax.swing
  java.desktop/javax.swing.border
  java.desktop/javax.swing.event
  java.desktop/sun.awt.image
  java.desktop/sun.swing
)

# Verify the upstream constructs the packaging relies on but does not patch,
# before downloading anything: the macOS data directories the launcher wrapper
# mirrors into (and the cask zaps), and Adventure Mode resolving `res/` from
# the working directory. These are compiled into the prebuilt jars and
# unpatched, so nothing else in the build would catch them changing.
echo "Verifying upstream source constructs."
assert_upstream_constructs "$RAW_BASE" "$ref" \
  'forge-gui/src/main/java/forge/localinstance/properties/ForgeProfileProperties.java=/Library/Application Support/Forge' \
  'forge-gui/src/main/java/forge/localinstance/properties/ForgeProfileProperties.java=/Library/Caches/Forge' \
  'forge-gui-mobile/src/forge/adventure/util/Config.java=Files.exists(Paths.get("./res"))'

echo "Preparing staging input for Forge '$version'."
stage="$work_dir/stage"
mkdir -p "$stage"

archive="$(obtain_archive "$url" "$archive" "$work_dir/forge.tar.bz2")"
echo "Extracting '$archive'."
tar xf "$archive" -C "$stage"

# Rename the version-stamped fat jars to stable names so the launcher
# configuration is version-independent. These globs assume upstream's `tar.bz2`
# extracts its contents directly into the staging directory (no wrapping
# directory), so each pattern matches one jar. The `fail` guards below abort
# loudly if a pattern matches nothing (a renamed jar or an added wrapping
# directory); a pattern matching more than one would silently take the first.
desktop_jar="$(find "$stage" -maxdepth 1 -name 'forge-gui-desktop-*-jar-with-dependencies.jar' | head -1)"
adventure_jar="$(find "$stage" -maxdepth 1 -name 'forge-gui-mobile-dev-*-jar-with-dependencies.jar' | head -1)"
editor_jar="$(find "$stage" -maxdepth 1 -name 'adventure-editor-jar-with-dependencies.jar' | head -1)"
[[ -n "$desktop_jar" ]] || fail 'Desktop jar not found in archive.'
[[ -n "$adventure_jar" ]] || fail 'Adventure Mode jar not found in archive.'
[[ -n "$editor_jar" ]] || fail 'Adventure Editor jar not found in archive.'
mv "$desktop_jar" "$stage/forge-desktop.jar"
mv "$adventure_jar" "$stage/forge-adventure-mode.jar"
mv "$editor_jar" "$stage/forge-adventure-editor.jar"
[[ -d "$stage/res" ]] || fail "No 'res' directory found in the archive."

# jpackage copies the entire input into the bundle and puts every jar on the
# classpath, so keep only the game resources, the three fat jars, and the
# license; drop the upstream platform launchers, documentation, and extra jars.
find "$stage" -mindepth 1 -maxdepth 1 \
  ! -name res \
  ! -name 'forge-desktop.jar' \
  ! -name 'forge-adventure-mode.jar' \
  ! -name 'forge-adventure-editor.jar' \
  ! -name 'LICENSE.txt' \
  -exec rm -rf {} +

# Disable Forge's built-in updater. Each patch targets one source file; the
# desktop classes live in `forge-desktop.jar`, the Adventure Mode prompt in
# `forge-adventure-mode.jar`. Each fat jar is self-contained, so the empty
# shared classpath makes each source compile against the jar it updates.
# `--release 17` must track Forge's own `maven.compiler.release`; if upstream
# raises its source level, the recompile fails (loudly) and 17 needs bumping.
echo "Disabling the built-in updater."
patch_targets=(
  "forge-gui/src/main/java/forge/download/AutoUpdater.java:$stage/forge-desktop.jar"
  "forge-gui-desktop/src/main/java/forge/view/FTitleBarBase.java:$stage/forge-desktop.jar"
  "forge-gui-desktop/src/main/java/forge/screens/home/settings/VSubmenuDownloaders.java:$stage/forge-desktop.jar"
  "forge-gui-mobile/src/forge/assets/AssetsDownloader.java:$stage/forge-adventure-mode.jar"
  "forge-gui-mobile-dev/src/forge/app/GameLauncher.java:$stage/forge-adventure-mode.jar"
)
apply_patches "$RAW_BASE" "$ref" "$script_dir/patches/forge" 17 "" \
  "$javac_bin" "$jar_bin" "$work_dir" "${patch_targets[@]}"

# Build the three Forge `.icns` icons, sharing a white rounded-squircle
# background for a consistent family look. The main icon is Forge's
# anvil-and-hammer glyph (the high-resolution Android logo); Adventure Mode and
# the Adventure Editor use their upstream Windows `.ico` artwork,
# low-resolution pixel art enlarged with nearest-neighbor integer scaling to
# keep the pixels crisp. Sources live in the Forge repository (GPL-3.0),
# fetched at the build ref.
ANVIL_SRC="forge-gui-android/res/drawable/logo.png"
ADVENTURE_SRC="forge-gui-mobile-dev/src/main/config/forge-adventure.ico"
EDITOR_SRC="adventure-editor/src/main/config/forge-adventure-editor.ico"

echo "Generating icons."
icon_dir="$work_dir/icons"
icon_work="$work_dir/icon-build"
mkdir -p "$icon_dir" "$icon_work"
icon_background "$MAGICK" "$icon_work" "$icon_work/bg.png"

curl -fsSL "$RAW_BASE/$ref/$ANVIL_SRC" -o "$icon_work/anvil.png"
compose_smooth "$icon_work/anvil.png" 512 "$icon_dir/Forge.icns"

curl -fsSL "$RAW_BASE/$ref/$ADVENTURE_SRC" -o "$icon_work/adventure.ico"
ico_largest_frame "$icon_work/adventure.ico" "$icon_work/adventure.png"
compose_pixel "$icon_work/adventure.png" 512 "$icon_dir/ForgeAdventureMode.icns"

curl -fsSL "$RAW_BASE/$ref/$EDITOR_SRC" -o "$icon_work/editor.ico"
ico_largest_frame "$icon_work/editor.ico" "$icon_work/editor.png"
compose_pixel "$icon_work/editor.png" 512 "$icon_dir/ForgeAdventureEditor.icns"

# Property files for the extra launchers. `java-options` is a single
# space-separated value; none of the tokens contain spaces.
adventure_opts="$HEAP"
for mod in "${add_opens[@]}"; do
  adventure_opts+=" --add-opens $mod=ALL-UNNAMED"
done
adventure_opts+=" -Dio.netty.tryReflectionSetAccessible=true -Dfile.encoding=UTF-8"

cat >"$work_dir/adventure.properties" <<EOF
main-jar=forge-adventure-mode.jar
icon=$icon_dir/ForgeAdventureMode.icns
description=Forge Adventure Mode
java-options=$adventure_opts
EOF

cat >"$work_dir/editor.properties" <<EOF
main-jar=forge-adventure-editor.jar
icon=$icon_dir/ForgeAdventureEditor.icns
description=Forge Adventure Mode content editor
java-options=$HEAP -Dfile.encoding=UTF-8
EOF

echo "Running jpackage."
app_out="$work_dir/app"
mkdir -p "$app_out"
"$jpackage_bin" \
  --type app-image \
  --name Forge \
  --app-version "$app_version" \
  --vendor "$VENDOR" \
  --copyright "Forge is licensed under GPL-3.0; see the bundled LICENSE.txt." \
  --description "Open-source Magic: The Gathering rules engine" \
  --input "$stage" \
  --main-jar forge-desktop.jar \
  --icon "$icon_dir/Forge.icns" \
  --mac-package-identifier "$BUNDLE_ID" \
  --mac-package-name Forge \
  --java-options "$HEAP" \
  --java-options "-Dio.netty.tryReflectionSetAccessible=true" \
  --java-options "-Dfile.encoding=UTF-8" \
  --add-launcher "Adventure Mode=$work_dir/adventure.properties" \
  --add-launcher "Adventure Editor=$work_dir/editor.properties" \
  --dest "$app_out"

app="$app_out/Forge.app"
[[ -d "$app" ]] || fail "jpackage did not produce 'Forge.app'."

# Make the per-mode icons available for the launchers' Dock icons (jpackage
# only installs the main icon).
cp "$icon_dir/ForgeAdventureMode.icns" "$app/Contents/Resources/ForgeAdventureMode.icns"
cp "$icon_dir/ForgeAdventureEditor.icns" "$app/Contents/Resources/ForgeAdventureEditor.icns"

echo "Wrapping launchers."
process_launcher Forge Forge Forge.icns
process_launcher "Adventure Mode" "Forge Adventure Mode" ForgeAdventureMode.icns
process_launcher "Adventure Editor" "Forge Adventure Editor" ForgeAdventureEditor.icns

echo "Assembling sibling apps."
make_sibling "Forge Adventure Mode" "Adventure Mode" "$BUNDLE_ID.adventure" \
  "$icon_dir/ForgeAdventureMode.icns"
make_sibling "Forge Adventure Editor" "Adventure Editor" "$BUNDLE_ID.editor" \
  "$icon_dir/ForgeAdventureEditor.icns"

# Confirm jpackage actually embedded the runtime before shipping (the siblings
# are thin exec stubs with no runtime of their own, so only the payload app is
# checked).
assert_bundled_runtime "$app"

echo "Ad-hoc signing bundles."
adhoc_sign_deep "$app"
adhoc_sign "$app_out/Forge Adventure Mode.app"
adhoc_sign "$app_out/Forge Adventure Editor.app"

# Smoke-test the signed Classic launcher headlessly. `sim` is Forge's
# simulation mode: it loads the full card database from `res/` and exits
# without a window. That it reads cards confirms what nothing else exercises:
# the bundled runtime starts, the launcher's classpath isolation holds, and
# Forge resolves `res/` from the working directory (the assumption the
# writable-res design rests on). `$HOME` and the JVM's `user.home` are both
# redirected to the work directory for a throwaway data copy; on macOS the JVM
# takes `user.home` from the account, not `$HOME`, so both need redirecting.
# Adventure Mode needs an OpenGL context a runner lacks, so it cannot be
# covered.
echo "Smoke-testing the Classic launcher (headless card load)."
smoke_home="$work_dir/smoke-home"
smoke_log="$work_dir/smoke.log"
mkdir -p "$smoke_home"
HOME="$smoke_home" JAVA_TOOL_OPTIONS="-Duser.home=$smoke_home" \
  "$app/Contents/MacOS/Forge" sim >"$smoke_log" 2>&1 &
smoke_pid=$!
i=0
while kill -0 "$smoke_pid" 2>/dev/null; do
  i=$((i + 1))
  if [[ "$i" -ge 180 ]]; then
    kill -9 "$smoke_pid" 2>/dev/null || true
    cat "$smoke_log" >&2
    fail 'Classic launcher smoke test timed out.'
  fi
  sleep 1
done
# `sim` exits 0 even with no decks, so the read-cards line, not the exit code,
# is the real signal that the database loaded from `res/`.
grep -qE 'Read cards: [1-9]' "$smoke_log" || {
  cat "$smoke_log" >&2
  fail "Classic launcher did not load any cards from 'res/'."
}
echo "Smoke test passed."

dmg="$out_dir/Forge-$version-arm64.dmg"
sha="$(make_dmg Forge "$dmg" \
  "$app" "$app_out/Forge Adventure Mode.app" "$app_out/Forge Adventure Editor.app")"
echo "Built '$dmg'."
echo "channel=${channel:-n/a} version=$version"
echo "sha256=$sha"
