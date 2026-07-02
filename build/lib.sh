#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Shared helpers for the per-app build scripts (`build-forge.sh` and
# `build-xmage.sh`). Sourced, not executed; it defines functions and sets no
# global state.

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# Rejects a version string containing characters an upstream version would not,
# so it cannot corrupt a disk image name or a `sed` that stamps a wrapper.
assert_safe_version() {
  [[ "$1" =~ ^[0-9][0-9A-Za-z.-]*$ ]] ||
    fail "Refusing unexpected version string '$1'."
}

# Echoes the strictly numeric prefix of a version (what jpackage requires for
# `--app-version`); fails if there is none.
numeric_app_version() {
  printf '%s' "$1" | grep -oE '^[0-9]+(\.[0-9]+)*' ||
    fail "No numeric version prefix in '$1'."
}

# Fails unless running on Apple silicon. The bundled runtime is the host
# architecture, so this `arm64`-only tap cannot cross-build.
require_arm64() {
  [[ "$(uname -m)" == arm64 ]] ||
    fail "Unsupported architecture: $(uname -m); this tap builds for arm64 only."
}

# Echoes the path to a JDK tool (jpackage, javac, jar), preferring `$JAVA_HOME`
# and falling back to `$PATH`.
jdk_tool() {
  local bin="${JAVA_HOME:+$JAVA_HOME/bin/}$1"
  command -v "$bin" >/dev/null 2>&1 || fail "JDK tool not found: $bin."
  printf '%s' "$bin"
}

# Ensures the upstream archive is present and echoes its path: a local archive
# is validated and used as is; otherwise the URL is downloaded to `dest`.
# Progress goes to stderr so the echoed path stays clean for capture.
obtain_archive() {
  local url="$1" archive="$2" dest="$3"
  if [[ -n "$archive" ]]; then
    [[ -f "$archive" ]] || fail "Archive not found: $archive."
    printf '%s' "$archive"
  else
    echo "Downloading $url." >&2
    curl -fSL "$url" -o "$dest"
    printf '%s' "$dest"
  fi
}

# Applies the source patches in `patches_dir/` to the bundled jars: fetches
# each target's source at the build ref, applies every patch, recompiles, and
# replaces the classes in the jar. `git apply --recount` tolerates shifted line
# numbers but still fails if a patched region changed, the signal that a patch
# needs adjusting.
#
# Each target is a `<source-relative-path>:<jar-to-update>` pair. An empty
# shared compile classpath builds each source against the jar it updates
# (enough for self-contained jars, as Forge's fat jars are); a `<directory>/*`
# classpath uses javac's classpath wildcard, not a shell glob, so pass it
# quoted.
apply_patches() {
  local raw_base="$1" ref="$2" patches_dir="$3" release="$4" compile_cp="$5"
  local javac="$6" jar="$7" work="$8"
  shift 8
  local targets=("$@")
  local src="$work/patch-src" out="$work/patch-out"
  mkdir -p "$src"

  local entry rel
  for entry in "${targets[@]}"; do
    rel="${entry%%:*}"
    mkdir -p "$src/$(dirname "$rel")"
    curl -fsSL "$raw_base/$ref/$rel" -o "$src/$rel"
  done

  local patch
  for patch in "$patches_dir"/*.patch; do
    (cd "$src" && git apply --recount "$patch") ||
      fail "Failed to apply '$(basename "$patch")' at ref '$ref' (upstream source may have changed)."
  done

  local jarfile cp classfile stem rc
  for entry in "${targets[@]}"; do
    rel="${entry%%:*}"
    jarfile="${entry##*:}"
    cp="${compile_cp:-$jarfile}"
    rm -rf "$out"
    mkdir -p "$out"
    "$javac" -cp "$cp" -d "$out" --release "$release" "$src/$rel"
    # `jar --update` only adds or replaces classes; it never removes stale
    # ones. Before re-adding, drop every top-level class the recompile emits
    # (with its inner classes) from the jar, so a recompile that produces fewer
    # inner or companion classes cannot leave a stale one behind. Exit 12 means
    # nothing matched (a newly added class), which is fine; any other failure
    # is fatal.
    while IFS= read -r classfile; do
      stem="${classfile#"$out/"}"
      stem="${stem%.class}"
      rc=0
      zip -q -d "$jarfile" "$stem.class" "$stem\$*.class" || rc=$?
      [[ "$rc" -eq 0 || "$rc" -eq 12 ]] ||
        fail "Failed to purge '$stem' from '$(basename "$jarfile")' (zip exit $rc)."
    done < <(find "$out" -type f -name '*.class' ! -name '*$*')
    "$jar" --update --file "$jarfile" -C "$out" .
  done
}

# Fails the build if an upstream source construct the packaging relies on but
# does not patch has changed or gone. Each argument is a
# `<source-relative-path>=<fixed-string>` pair; the file is fetched at the ref
# and grepped for the string. These constructs are compiled away in the
# prebuilt artifact, so a structural check of the download cannot see them, and
# they are not patched, so `apply_patches` has no tripwire for them; fetching
# the source is the only way to catch a change.
assert_upstream_constructs() {
  local raw_base="$1" ref="$2"
  shift 2
  local work spec path signature cached
  local missing=()
  work="$(mktemp -d)"
  for spec in "$@"; do
    path="${spec%%=*}"
    signature="${spec#*=}"
    cached="$work/${path//\//_}"
    [[ -f "$cached" ]] ||
      curl -fsSL -o "$cached" "$raw_base/$ref/$path" ||
      fail "Could not fetch '$path' at '$ref' to verify upstream constructs."
    grep -Fq -- "$signature" "$cached" || missing+=("$path: $signature")
  done
  rm -rf "$work"
  if ((${#missing[@]} > 0)); then
    printf 'Upstream no longer contains a construct this tap relies on:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    fail 'Review the upstream changes and adjust the packaging.'
  fi
}

# Fails the build unless a jpackage app-image bundle ships a Java runtime.
# jpackage embeds a trimmed runtime at `Contents/runtime/` with no `bin/` (the
# native launcher boots the JVM through `libjli.dylib` directly), so the check
# asserts that library is present; it catches a jpackage change that stopped
# bundling the runtime, which would break the no-prerequisite promise. Thin
# sibling bundles only exec into another app, so they are not passed here.
assert_bundled_runtime() {
  local app="$1"
  [[ -f "$app/Contents/runtime/Contents/Home/lib/libjli.dylib" ]] ||
    fail "No bundled Java runtime in '$(basename "$app")'; the jpackage layout changed."
}

# Renames a jpackage launcher and its configuration to `<name>-bin`, freeing
# the original name for a wrapper. The native launcher derives its `.cfg` name
# from the executable name, so both must be renamed together.
rename_launcher() {
  local app="$1" name="$2"
  mv "$app/Contents/MacOS/$name" "$app/Contents/MacOS/$name-bin"
  mv "$app/Contents/app/$name.cfg" "$app/Contents/app/$name-bin.cfg"
}

# Ad-hoc signs a bundle (`codesign --sign -`); no Apple Developer identity is
# needed. The deep variant signs nested code (the bundled runtime and jars);
# the shallow variant is for the thin sibling bundles, which contain only a
# stub.
adhoc_sign_deep() {
  codesign --force --deep --sign - "$1"
}

adhoc_sign() {
  codesign --force --sign - "$1"
}

# Builds a compressed disk image from the bundles, with an `/Applications`
# symlink for drag-to-install, then writes its SHA-256 sidecar and echoes the
# checksum. Progress goes to stderr so the echoed checksum stays clean.
make_dmg() {
  local volname="$1" dmg="$2"
  shift 2
  local root
  root="$(mktemp -d)"
  cp -R "$@" "$root/"
  ln -s /Applications "$root/Applications"
  rm -f "$dmg"
  echo "Building disk image." >&2
  hdiutil create -volname "$volname" -srcfolder "$root" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$root"
  local sha
  sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  printf '%s\n' "$sha" >"$dmg.sha256"
  printf '%s' "$sha"
}

# Builds the shared 1024x1024 white rounded-squircle icon background into
# `out_png` (macOS does not round app icons itself, so the bundle must supply
# the shape).
icon_background() {
  local magick="$1" work="$2" out_png="$3"
  "$magick" -size 832x832 xc:white "$work/icon-bg-fill.png"
  "$magick" -size 832x832 xc:black -fill white \
    -draw 'roundrectangle 0,0,831,831,168,168' "$work/icon-bg-mask.png"
  "$magick" "$work/icon-bg-fill.png" "$work/icon-bg-mask.png" \
    -alpha off -compose CopyOpacity -composite "$work/icon-bg-832.png"
  "$magick" "$work/icon-bg-832.png" -background none \
    -gravity center -extent 1024x1024 "PNG32:$out_png"
}

# Packs a 1024x1024 PNG into a macOS `.icns`, generating the standard iconset
# resolutions with sips and packing them with iconutil.
png_to_icns() {
  local png="$1" icns="$2" work="$3"
  local iconset
  iconset="$work/$(basename "$icns" .icns).iconset"
  mkdir -p "$iconset"
  local size
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$png" \
      --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icns"
}
