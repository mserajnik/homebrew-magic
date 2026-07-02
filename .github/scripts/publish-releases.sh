#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Publishes the built disk images to the tap's own GitHub releases and bumps
# the casks to match. Per-version releases (Forge stable, XMage) get a tag per
# version; the Forge snapshot uses a single rolling `forge-snapshot` release.
# Old per-version releases are pruned per app, keeping only the most recent
# few; the rolling Forge snapshot keeps its tag but its old date-stamped assets
# are removed so it does not grow without bound. Committing the bumped casks is
# left to `commit-via-api.sh`.
#
# Expects build artifacts under `artifacts/<app>-<channel>-arm64/` and reads
# `BUILD_FORGE_STABLE`, `FORGE_STABLE_VERSION`, `BUILD_FORGE_SNAPSHOT`,
# `FORGE_SNAPSHOT_VERSION`, `BUILD_XMAGE`, `XMAGE_VERSION`,
# `GITHUB_REPOSITORY`, and `GH_TOKEN` from the environment.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env GITHUB_REPOSITORY
repo="$GITHUB_REPOSITORY"
keep_forge_stable=3
keep_xmage=3

# Locates the built disk image (named `<prefix>-<version>-arm64.dmg`) under the
# downloaded artifacts, or prints nothing if its build did not complete.
# `download-artifact` extracts a lone artifact straight into `artifacts/` but
# nests under a per-artifact subdirectory once a run produces more than one, so
# search recursively by name.
dmg_for() {
  local prefix="$1" version="$2"
  find artifacts -type f -name "$prefix-$version-arm64.dmg" -print -quit 2>/dev/null
}

# Publishes (or re-publishes) a release with the given disk images.
publish() {
  local tag="$1" title="$2" notes="$3" prerelease="$4"
  shift 4
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release upload "$tag" "$@" --repo "$repo" --clobber
    return
  fi
  local extra=()
  if [[ "$prerelease" == true ]]; then
    extra+=(--prerelease)
  fi
  gh release create "$tag" "$@" --repo "$repo" \
    --title "$title" --notes "$notes" "${extra[@]}"
}

# Rewrites a cask's version and SHA-256 in place.
bump_cask() {
  local file="$1" version="$2" sha="$3"
  sed -i -E \
    -e "s/(version \")[^\"]+(\")/\1$version\2/" \
    -e "s/(sha256 \")[0-9a-f]{64}(\")/\1$sha\2/" \
    "$file"
  # A `sed` that matches nothing exits 0, so confirm both edits actually
  # landed; otherwise a cask format change would publish the release but leave
  # the cask pointing at the old version and checksum.
  grep -qF "version \"$version\"" "$file" ||
    fail "Failed to update version in '$file'; cask format may have changed."
  grep -qF "sha256 \"$sha\"" "$file" ||
    fail "Failed to update sha256 in '$file'; cask format may have changed."
}

# Prunes old per-version releases with the given tag prefix, keeping the most
# recent few. Only version-shaped tags count (the prefix must be followed by a
# digit), so the rolling `forge-snapshot` release is never pruned even though
# it shares the `forge-` prefix. A skip tag (the release this run just
# published) is never pruned: a dispatch of an older version uploads to a
# pre-existing release without renewing its date, so it would otherwise sort as
# old.
prune() {
  local prefix="$1" keep="$2" skip="$3"
  echo "Pruning old $prefix releases (keeping $keep)."
  # Pruning is cleanup, never a gate: a transient API failure here must not
  # abort the run after the release and cask bump are already done, so
  # list/delete failures only warn (the next run reprunes).
  local old_tags
  old_tags="$(gh release list --repo "$repo" --limit 100 --json tagName \
    --jq ".[].tagName | select(startswith(\"$prefix\") and (ltrimstr(\"$prefix\") | test(\"^[0-9]\")))" | tail -n "+$((keep + 1))")" || {
    echo "::warning::Could not list releases; skipping $prefix prune."
    return 0
  }
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    if [[ -n "$skip" && "$tag" == "$skip" ]]; then
      continue
    fi
    echo "Deleting old release '$tag'."
    gh release delete "$tag" --repo "$repo" --cleanup-tag --yes ||
      echo "::warning::Could not delete release '$tag'."
  done <<<"$old_tags"
}

# Deletes every asset of a release except the named one. The rolling Forge
# snapshot release is replaced in place, but its disk image name embeds a build
# date, so a plain upload would add a new asset each day and the release would
# grow without bound (`prune` only deletes per-version release tags, never
# assets within a release). The new asset is uploaded before this runs, so the
# release is never left empty.
prune_assets() {
  local tag="$1" keep="$2" names
  # Best-effort, like `prune`: a failure must not abort the run after
  # publishing.
  names="$(gh release view "$tag" --repo "$repo" --json assets \
    --jq ".assets[].name | select(. != \"$keep\")")" || {
    echo "::warning::Could not list assets; skipping asset prune for '$tag'."
    return 0
  }
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    echo "Deleting old Forge snapshot asset '$name'."
    gh release delete-asset "$tag" "$name" --repo "$repo" --yes ||
      echo "::warning::Could not delete asset '$name'."
  done <<<"$names"
}

if [[ "${BUILD_FORGE_STABLE:-false}" == true ]]; then
  dmg="$(dmg_for Forge "$FORGE_STABLE_VERSION")"
  if [[ -n "$dmg" && -f "$dmg.sha256" ]]; then
    echo "Publishing Forge stable '$FORGE_STABLE_VERSION'."
    publish "forge-$FORGE_STABLE_VERSION" "Forge $FORGE_STABLE_VERSION" \
      "Forge $FORGE_STABLE_VERSION packaged for macOS." false "$dmg"
    bump_cask Casks/forge.rb "$FORGE_STABLE_VERSION" "$(cat "$dmg.sha256")"
  else
    echo "Skipping Forge stable: build did not complete."
  fi
fi

if [[ "${BUILD_FORGE_SNAPSHOT:-false}" == true ]]; then
  dmg="$(dmg_for Forge "$FORGE_SNAPSHOT_VERSION")"
  if [[ -n "$dmg" && -f "$dmg.sha256" ]]; then
    echo "Publishing Forge snapshot '$FORGE_SNAPSHOT_VERSION'."
    publish forge-snapshot "Forge Snapshot" "Rolling daily Forge snapshot, packaged for macOS." true "$dmg"
    prune_assets forge-snapshot "$(basename "$dmg")"
    bump_cask "Casks/forge@snapshot.rb" "$FORGE_SNAPSHOT_VERSION" "$(cat "$dmg.sha256")"
  else
    echo "Skipping Forge snapshot: build did not complete."
  fi
fi

if [[ "${BUILD_XMAGE:-false}" == true ]]; then
  dmg="$(dmg_for XMage "$XMAGE_VERSION")"
  if [[ -n "$dmg" && -f "$dmg.sha256" ]]; then
    echo "Publishing XMage '$XMAGE_VERSION'."
    publish "xmage-$XMAGE_VERSION" "XMage $XMAGE_VERSION" \
      "XMage $XMAGE_VERSION packaged for macOS." false "$dmg"
    bump_cask Casks/xmage.rb "$XMAGE_VERSION" "$(cat "$dmg.sha256")"
  else
    echo "Skipping XMage: build did not complete."
  fi
fi

forge_stable_skip=""
if [[ "${BUILD_FORGE_STABLE:-false}" == true ]]; then forge_stable_skip="forge-$FORGE_STABLE_VERSION"; fi
xmage_skip=""
if [[ "${BUILD_XMAGE:-false}" == true ]]; then xmage_skip="xmage-$XMAGE_VERSION"; fi
prune "forge-" "$keep_forge_stable" "$forge_stable_skip"
prune "xmage-" "$keep_xmage" "$xmage_skip"
