# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# shellcheck shell=bash

# Shared helpers sourced by the other scripts in this directory: error
# handling, environment variable checks, and output writers for GitHub Actions.

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"

  if [[ -z "${!name:-}" ]]; then
    fail "Environment variable '$name' is required."
  fi
}

write_output() {
  require_env GITHUB_OUTPUT

  local name="$1"
  local value="$2"

  printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
}
