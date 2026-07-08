# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Embedded verbatim into the bundle's `/bin/sh` seeding script by
# `write_seeding_script`, so it must stay POSIX `sh`.
# shellcheck shell=sh

# The XMage server's `config.xml` carries two concerns: the operator-editable
# `<server>` element (connection, authentication, AI, and mail settings) and
# the version-coupled plugin registrations (game/player/tournament/deck/cube
# `jar="mage-...-<version>.jar"` references). On an upgrade the shipped plugins
# are replaced wholesale, so the registrations must always come from the new
# release; only the `<server>` element is worth carrying across. This is that
# merge; the build's round-trip guard (`verify_config_transform`) sources this
# same file, so it tests the exact transform the bundle ships.

# Merges the operator's `<server>` settings into a freshly shipped
# configuration. Takes the fresh configuration, the user's existing
# configuration, and an output path; writes to the output the fresh
# configuration with every `<server>` attribute the user's configuration also
# sets replaced by the user's value, and everything outside the `<server>`
# element (notably the version-stamped plugin references) kept exactly as the
# fresh configuration ships it. Nothing outside the element is ever touched, so
# a plugin reference or an unrelated element cannot be rewritten even if a
# hand-edited configuration is malformed. Values are emitted literally, so an
# `&`, a `\`, or a bracket in a user value needs no escaping.
merge_server_config() {
  cfg_fresh=$1
  cfg_user=$2
  cfg_out=$3
  # Pass 1 reads the user's configuration and collects its `<server>` attribute
  # values into `val`. Pass 2 re-emits the fresh configuration verbatim, but
  # inside its own `<server>` element replaces each attribute value that `val`
  # provides. The element opens at a `<server` tag matched with a following
  # delimiter (so a `<serverList` sibling is not mistaken for it) and closes at
  # the first `>` that is not inside a quoted value: quoted spans are stripped
  # before the test, so a `>` in an attribute value cannot end the element
  # early.
  awk -v userfile="$cfg_user" '
    FNR == 1 { inblk = 0 }
    FILENAME == userfile {
      if ($0 ~ /<server[[:space:]>]/) inblk = 1
      if (inblk) {
        s = $0
        while (match(s, /[A-Za-z_][A-Za-z0-9_]*="[^"]*"/)) {
          tok = substr(s, RSTART, RLENGTH)
          eq = index(tok, "=")
          val[substr(tok, 1, eq - 1)] = substr(tok, eq + 2, length(tok) - eq - 2)
          s = substr(s, RSTART + RLENGTH)
        }
        t = $0
        gsub(/"[^"]*"/, "", t)
        if (index(t, ">")) inblk = 0
      }
      next
    }
    {
      if ($0 ~ /<server[[:space:]>]/) inblk = 1
      if (inblk) {
        out = ""
        s = $0
        while (match(s, /[A-Za-z_][A-Za-z0-9_]*="[^"]*"/)) {
          tok = substr(s, RSTART, RLENGTH)
          eq = index(tok, "=")
          nm = substr(tok, 1, eq - 1)
          if (nm in val) tok = nm "=\"" val[nm] "\""
          out = out substr(s, 1, RSTART - 1) tok
          s = substr(s, RSTART + RLENGTH)
        }
        print out s
        t = $0
        gsub(/"[^"]*"/, "", t)
        if (index(t, ">")) inblk = 0
      } else {
        print
      }
    }
  ' "$cfg_user" "$cfg_fresh" >"$cfg_out"
}
