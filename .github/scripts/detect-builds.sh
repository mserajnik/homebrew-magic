#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Decides which channels need building and emits GitHub Actions outputs: a
# build matrix (one `arm64` entry per channel) plus per-channel metadata. A
# channel is built when the build is forced (a dispatch or a pull request) or
# when its upstream version differs from the one its cask records, so a
# scheduled run skips a channel already built.
#
# Covers Forge (stable and snapshot) and XMage; each matrix entry carries an
# `app` so the build job knows which build script to run.
#
# Reads `TARGET` and `EVENT` (the workflow event) from the environment.
# `TARGET` selects which builds to run, as a `workflow_dispatch` label or its
# short token (see the mapping below).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

target="${TARGET:-all}"
event="${EVENT:-workflow_dispatch}"
forge_repo="Card-Forge/forge"
xmage_repo="magefree/mage"

# A dispatch or a pull request forces a build regardless of the recorded cask
# version: a dispatch is an explicit rebuild request, and a pull request must
# exercise the build even in steady state (the release job never publishes from
# a pull request). Any other event builds a channel only when its upstream
# version has moved.
force=false
case "$event" in
  workflow_dispatch | pull_request) force=true ;;
esac

# Map the dispatch target (a human-readable label or its short token) to which
# builds to run. An unknown value falls back to building everything rather than
# silently building nothing.
want_forge_stable=false
want_forge_snapshot=false
want_xmage=false
case "$target" in
  all | Everything)
    want_forge_stable=true
    want_forge_snapshot=true
    want_xmage=true
    ;;
  forge | "Both Forge channels")
    want_forge_stable=true
    want_forge_snapshot=true
    ;;
  forge_stable | "Forge stable only")
    want_forge_stable=true
    ;;
  forge_snapshot | "Forge snapshot only")
    want_forge_snapshot=true
    ;;
  xmage | "XMage only")
    want_xmage=true
    ;;
  *)
    echo "::warning::Unknown build target '$target'; building everything." >&2
    want_forge_stable=true
    want_forge_snapshot=true
    want_xmage=true
    ;;
esac

# True if a version contains only what a Forge or XMage version uses, so it
# cannot corrupt a download URL, a filename, or the `sed` that rewrites the
# casks. A non-matching version is skipped (with a warning) rather than fatal,
# so a malformed upstream release cannot block the other channels.
is_safe_version() {
  [[ "$1" =~ ^[0-9][0-9A-Za-z.-]*$ ]]
}

# Echoes the version a cask currently records.
cask_version() {
  awk -F'"' '/^[[:space:]]*version "/ { print $2; exit }' "$1"
}

# The `detect_*` functions resolve each channel's upstream version and set its
# globals, returning non-zero if the lookup fails, yields nothing, or yields an
# unexpected version. The globals are promoted only after the lookup succeeds,
# so a skipped channel leaves them empty rather than holding a `gh api` error
# body. Channels are independent: one upstream's outage or a malformed release
# skips only that channel, never the others.

build_forge_stable=false
forge_stable_version=""
forge_stable_tag=""
detect_forge_stable() {
  local tag
  tag="$(gh api "repos/$forge_repo/releases/latest" --jq '.tag_name')" || return 1
  is_safe_version "${tag#forge-}" || {
    echo "::warning::Ignoring unexpected Forge stable version '${tag#forge-}'." >&2
    return 1
  }
  forge_stable_tag="$tag"
  forge_stable_version="${tag#forge-}"
  if [[ "$force" == true || "$forge_stable_version" != "$(cask_version Casks/forge.rb)" ]]; then
    build_forge_stable=true
  fi
}

build_forge_snapshot=false
forge_snapshot_version=""
detect_forge_snapshot() {
  local asset version
  asset="$(gh api "repos/$forge_repo/releases/tags/daily-snapshots" \
    --jq '[.assets[].name | select(test("^forge-installer-.*\\.tar\\.bz2$"))][0] // empty')" || return 1
  version="$(sed -E 's/^forge-installer-(.*)\.tar\.bz2$/\1/' <<<"$asset")"
  [[ -n "$version" ]] || return 1
  is_safe_version "$version" || {
    echo "::warning::Ignoring unexpected Forge snapshot version '$version'." >&2
    return 1
  }
  forge_snapshot_version="$version"
  if [[ "$force" == true || "$forge_snapshot_version" != "$(cask_version 'Casks/forge@snapshot.rb')" ]]; then
    build_forge_snapshot=true
  fi
}

# XMage publishes regular releases only (no snapshot channel). The release tag
# (`xmage_X.Y.ZZVn`) is the version, not the jar version: the `Vn` suffix marks
# re-releases of the same base version, so it is what distinguishes a build.
# The single asset's filename embeds a build date, so its URL is read, not
# built.
build_xmage=false
xmage_version=""
xmage_tag=""
xmage_url=""
detect_xmage() {
  local release tag url
  # Read the release once so the version and the asset URL always come from the
  # same release; a second fetch could straddle an upstream release cut.
  release="$(gh api "repos/$xmage_repo/releases/latest")" || return 1
  tag="$(jq -r '.tag_name // empty' <<<"$release")"
  is_safe_version "${tag#xmage_}" || {
    echo "::warning::Ignoring unexpected XMage version '${tag#xmage_}'." >&2
    return 1
  }
  url="$(jq -r '[.assets[] | select(.name | test("^mage-full_.*\\.zip$")) | .browser_download_url][0] // empty' <<<"$release")"
  [[ -n "$url" ]] || return 1
  # Unlike the Forge URLs (built from an `is_safe_version` version), this URL
  # is taken verbatim from the API, so restrict it to a plain GitHub download
  # URL. The build job passes it through the environment rather than the shell,
  # and this rejects anything carrying shell metacharacters as a second layer.
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._~%/-]+$ ]] || {
    echo "::warning::Ignoring unexpected XMage asset URL '$url'." >&2
    return 1
  }
  xmage_tag="$tag"
  xmage_version="${tag#xmage_}"
  xmage_url="$url"
  if [[ "$force" == true || "$xmage_version" != "$(cask_version Casks/xmage.rb)" ]]; then
    build_xmage=true
  fi
}

if [[ "$want_forge_stable" == true ]]; then
  detect_forge_stable || echo "::warning::Forge stable detection failed; skipping." >&2
fi
if [[ "$want_forge_snapshot" == true ]]; then
  detect_forge_snapshot || echo "::warning::Forge snapshot detection failed; skipping." >&2
fi
if [[ "$want_xmage" == true ]]; then
  detect_xmage || echo "::warning::XMage detection failed; skipping." >&2
fi

include="$(jq -nc '[]')"
add() {
  local app="$1" ch="$2" ver="$3" ref="$4" url="$5"
  include="$(jq -c \
    --arg app "$app" --arg channel "$ch" --arg version "$ver" \
    --arg ref "$ref" --arg url "$url" --arg runner macos-26 \
    '. + [{app: $app, channel: $channel, version: $version, ref: $ref, url: $url, runner: $runner}]' \
    <<<"$include")"
}

if [[ "$build_forge_stable" == true ]]; then
  add forge stable "$forge_stable_version" "$forge_stable_tag" \
    "https://github.com/$forge_repo/releases/download/$forge_stable_tag/forge-installer-$forge_stable_version.tar.bz2"
fi
if [[ "$build_forge_snapshot" == true ]]; then
  add forge snapshot "$forge_snapshot_version" daily-snapshots \
    "https://github.com/$forge_repo/releases/download/daily-snapshots/forge-installer-$forge_snapshot_version.tar.bz2"
fi
if [[ "$build_xmage" == true ]]; then
  add xmage stable "$xmage_version" "$xmage_tag" "$xmage_url"
fi

any=false
if [[ "$build_forge_stable" == true || "$build_forge_snapshot" == true || "$build_xmage" == true ]]; then
  any=true
fi

write_output any "$any"
write_output matrix "$include"
write_output build_forge_stable "$build_forge_stable"
write_output forge_stable_version "$forge_stable_version"
write_output build_forge_snapshot "$build_forge_snapshot"
write_output forge_snapshot_version "$forge_snapshot_version"
write_output build_xmage "$build_xmage"
write_output xmage_version "$xmage_version"
