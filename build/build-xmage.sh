#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Builds the macOS XMage app bundles and a distributable disk image from an
# upstream XMage release.
#
# The upstream `.zip` ships a ready-to-run client (`xmage/mage-client/`) and
# server (`xmage/mage-server/`), each a main jar plus a `lib/` of dependency
# jars and read-only resource directories. Each is packaged with jpackage into
# its own bundle that bundles a Java runtime: `XMage.app` (the Swing client)
# and `XMage Server.app` (the headless server). Both are ad-hoc signed and
# wrapped into a single `.dmg`, and its SHA-256 is reported for the cask.
#
# Unlike Forge, XMage's main jars are not fat: dependencies live in `lib/` and
# are pulled in via the jar manifest's `Class-Path`. jpackage's default
# launcher runs `java -jar` and would honor that manifest; passing
# `--main-class` instead makes it run `java -cp <every jar in the input>`, so
# the bundled `lib/` directory is authoritative and the manifest is irrelevant.
# This also lets the `sqlite-jdbc` swap below take effect (see
# `SQLITE_JDBC_VERSION`).
#
# XMage resolves its resources and writes its data (the card database, the card
# image cache, logs) relative to the working directory. The bundles ship those
# resources read-only, so each launcher wrapper seeds them into a writable
# directory under `~/Library/Application Support` and runs from there. The
# server additionally opens in a Terminal window so its log is visible and it
# can be stopped.
#
# Usage:
#   build-xmage.sh --version <version> --url <zip-url> [options]
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

BUNDLE_ID="${BUNDLE_ID_PREFIX:-at.mser}.xmage"
VENDOR="${VENDOR:-Michael Serajnik}"
CLIENT_HEAP="-Xmx2048m"
SERVER_HEAP="-Xmx1024m"
MAGICK="${MAGICK:-magick}"
RAW_BASE="https://raw.githubusercontent.com/magefree/mage"

# XMage bundles `sqlite-jdbc` 3.32.3.2 (July 2020), whose only macOS native
# library is `x86_64`; the official launcher ships an `x86_64` runtime and runs
# it under Rosetta. This tap bundles a native `arm64` runtime, so that
# version's server crashes loading its `user_stats` database. Swap in a current
# `sqlite-jdbc`, which ships an `arm64` native, before packaging the server.
# This is the only upstream jar this build replaces; the swap below fails the
# build if no `sqlite-jdbc` jar is present to replace.
SQLITE_JDBC_VERSION="3.50.3.0"
SQLITE_JDBC_URL="https://repo1.maven.org/maven2/org/xerial/sqlite-jdbc/$SQLITE_JDBC_VERSION/sqlite-jdbc-$SQLITE_JDBC_VERSION.jar"

# The client and server talk over JBoss Remoting, whose serialization reflects
# into `java.io.ObjectOutputStream` internals. Upstream runs on Java 8, where
# that is allowed; on the bundled Java 25 it is blocked by default and the
# client cannot connect to any server (an `InaccessibleObjectException` the
# moment it serializes the login request). Opening `java.base/java.io` is the
# whole fix, on both bundles: a full client-server game was verified to need
# nothing more (game state serializes through the same path, but as XMage's own
# classpath classes, which need no opens). The smoke test connects a headless
# client with this option to confirm it still suffices against each release.
XMAGE_ADD_OPENS="--add-opens=java.base/java.io=ALL-UNNAMED"

# Builds the shared `XMage.icns` from the XMage wordmark on a white rounded
# squircle. The wordmark is the highest-resolution XMage brand asset (509x288),
# scaled 1.5x on the 1024 master, which fits the available space better than
# the native resolution and still looks fine.
make_icon() {
  local src="$1" out="$2"
  local w="$work_dir/icon"
  mkdir -p "$w"
  icon_background "$MAGICK" "$w" "$w/bg.png"
  "$MAGICK" "$src" -trim +repage -resize 150% "$w/fg.png"
  "$MAGICK" "$w/bg.png" "$w/fg.png" \
    -gravity center -compose over -composite "PNG32:$w/icon.png"
  png_to_icns "$w/icon.png" "$out" "$w"
}

# Packages one XMage component (client or server) with jpackage and echoes the
# bundle path. Only `lib/` is the jpackage input, so only the dependency jars
# land on the classpath; the resource directories and files XMage reads
# relative to its working directory are copied into `Resources/payload/` for
# the wrapper to seed (they are not jars and must stay off the classpath,
# notably the server plugin jars it discovers under `plugins/`).
package_component() {
  local app_name="$1" src="$2" main_jar="$3" main_class="$4" heap="$5"
  local identifier="$6" description="$7"
  shift 7
  local payload_items=("$@")

  echo "Running jpackage for '$app_name'." >&2
  local app_out="$work_dir/app"
  mkdir -p "$app_out"
  "$jpackage_bin" \
    --type app-image \
    --name "$app_name" \
    --app-version "$app_version" \
    --vendor "$VENDOR" \
    --copyright "XMage is licensed under MIT; see the bundled LICENSE.txt." \
    --description "$description" \
    --input "$src/lib" \
    --main-jar "$(basename "$main_jar")" \
    --main-class "$main_class" \
    --icon "$icns" \
    --mac-package-identifier "$identifier" \
    --mac-package-name "$app_name" \
    --java-options "$heap" \
    --java-options "-Dfile.encoding=UTF-8" \
    --java-options "-Dsun.jnu.encoding=UTF-8" \
    --java-options "-Djava.net.preferIPv4Stack=true" \
    --java-options "$XMAGE_ADD_OPENS" \
    --dest "$app_out"

  local app="$app_out/$app_name.app"
  [[ -d "$app" ]] || fail "jpackage did not produce '$app_name.app'."

  # Bundle the component's MIT license so the redistributed app carries XMage's
  # license notice (which `--copyright` references), mirroring how Forge
  # bundles its `LICENSE.txt`. Required: fail loudly if upstream ever stops
  # shipping it.
  [[ -f "$src/LICENSE.txt" ]] ||
    fail "Missing 'LICENSE.txt' in '$(basename "$src")'; cannot bundle the XMage license."
  cp "$src/LICENSE.txt" "$app/Contents/app/LICENSE.txt"

  local payload="$app/Contents/Resources/payload"
  mkdir -p "$payload"
  # Fail loudly if a resource we depend on is gone: an upstream layout change
  # that drops or renames one of these must get our attention, not silently
  # ship a bundle missing it (the server smoke test would still pass without,
  # say, the plugins the server loads at runtime).
  local item
  for item in "${payload_items[@]}"; do
    [[ -e "$src/$item" ]] ||
      fail "Resource '$item' missing from '$(basename "$src")'; upstream layout changed."
    cp -R "$src/$item" "$payload/$item"
  done

  printf '%s' "$app"
}

# Writes a `/bin/sh` seeding script that mirrors the payload items into a
# writable working directory under `~/Library/Application Support`, then runs
# the target launcher from there. Each item is a `name:policy` pair telling the
# script how to refresh it on a version change:
#
# - m  Merge (ditto): overwrite same-named files but leave unlisted siblings
#   alone. Used for everything that shares a directory with user-generated
#   data, notably the client's `plugins` (the card image cache lives under
#   `plugins/images/`) and `backgrounds` / `sample-decks` (user additions
#   stay).
# - r  Replace (remove, then copy): the directory is a pure read-only template,
#   so stale files must go. Used for the server's `plugins`, whose jar names
#   embed the XMage version; a plain merge would leave the previous version's
#   jars beside the new ones and confuse plugin loading.
# - c  Configuration directory: refresh the static defaults but preserve a
#   user-edited `config.xml`. Used for the server's `config` so its port,
#   authentication, and AI settings survive an upgrade while shipped defaults
#   still update.
#
# Runtime data the app creates itself (the card database under `db/`, logs,
# `gamesHistory/`, `saved/`) is never a listed item, so no policy ever touches
# it. The body is a literal template; the per-app values are substituted
# afterwards.
write_seeding_script() {
  local out="$1" data_dir="$2" target="$3"
  shift 3
  local items="$*"
  cat >"$out" <<'WRAP'
#!/bin/sh

set -e

here="$(cd "$(dirname "$0")" && pwd)"
payload="$here/../Resources/payload"
workdir="$HOME/Library/Application Support/__DATA_DIR__"
stamp="$workdir/.payload-version"
payload_version="__VERSION__"
lock="$workdir/.payload-lock"
items="__ITEMS__"

needs_seed() {
  [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$payload_version" ]
}

seed() {
  for spec in $items; do
    name="${spec%:*}"
    policy="${spec##*:}"
    src="$payload/$name"
    dst="$workdir/$name"
    [ -e "$src" ] || continue
    case "$policy" in
      r)
        # Read-only template: drop the old version's files before copying.
        rm -rf "$dst"
        /usr/bin/ditto "$src" "$dst"
        ;;
      c)
        # Refresh the shipped configuration defaults without ever overwriting a
        # user-edited `config.xml`: stage the defaults, drop `config.xml` from
        # the staging copy when the user already has one, then merge the rest.
        # The user's file is never written, so no crash can revert it; a fresh
        # install (no `config.xml` yet) gets the default like the other files.
        staging="$workdir/.config-staging"
        rm -rf "$staging"
        /usr/bin/ditto "$src" "$staging"
        if [ -f "$dst/config.xml" ]; then
          rm -f "$staging/config.xml"
        fi
        /usr/bin/ditto "$staging" "$dst"
        rm -rf "$staging"
        ;;
      *)
        # Merge: overwrite same-named files, leave user-generated siblings.
        /usr/bin/ditto "$src" "$dst"
        ;;
    esac
  done
  printf '%s' "$payload_version" >"$stamp"
}

if needs_seed; then
  mkdir -p "$workdir"
  # Serialize the seed across launches started at once: the winner seeds while
  # the others wait. A lock is reclaimed only once it is older than five
  # minutes, so a crashed seed clears without a still-active lock being
  # removed.
  while needs_seed; do
    if mkdir "$lock" 2>/dev/null; then
      if needs_seed; then seed; fi
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
exec "$here/__TARGET__" "$@"
WRAP
  # The data directory, target, and items contain no `|`, so it is a safe
  # delimiter; the version is already validated to a restricted character set.
  sed -i '' \
    -e "s|__DATA_DIR__|$data_dir|" \
    -e "s|__VERSION__|$version|" \
    -e "s|__ITEMS__|$items|" \
    -e "s|__TARGET__|$target|" \
    "$out"
  chmod +x "$out"
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
java_bin="$(jdk_tool java)"

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work_dir="$(mktemp -d)"
trap '[ -n "${smoke_pid:-}" ] && kill -9 "$smoke_pid" 2>/dev/null || true; rm -rf "$work_dir"' EXIT INT TERM

echo "Preparing staging input for XMage '$version'."
stage="$work_dir/stage"
mkdir -p "$stage"
archive="$(obtain_archive "$url" "$archive" "$work_dir/mage-full.zip")"
echo "Extracting '$archive'."
# Extract with ditto rather than unzip: a sample-deck filename contains a
# non-ASCII byte that unzip mishandles on APFS (it reports a spurious write
# error and aborts), while ditto decodes the zip's filename encoding correctly.
# It cannot select sub-paths, so the whole archive is extracted; only the
# client and server trees are used and the launcher bundle is ignored.
ditto -x -k "$archive" "$stage"

client_src="$stage/xmage/mage-client"
server_src="$stage/xmage/mage-server"
[[ -d "$client_src/lib" ]] || fail "No 'mage-client/lib' in the zip."
[[ -d "$server_src/lib" ]] || fail "No 'mage-server/lib' in the zip."

client_jar="$(find "$client_src/lib" -maxdepth 1 -name 'mage-client-*.jar' | head -1)"
server_jar="$(find "$server_src/lib" -maxdepth 1 -name 'mage-server-*.jar' | head -1)"
[[ -n "$client_jar" ]] || fail "Client jar not found in 'mage-client/lib'."
[[ -n "$server_jar" ]] || fail "Server jar not found in 'mage-server/lib'."

# Guard the dependency set. The client and server classpaths are every jar in
# their `lib/`, so a dropped jar can break a class at runtime (which the smoke
# tests would not necessarily catch on the client side) and an added one may go
# unhandled. Compare the version-stripped jar names against a recorded
# baseline: a removed name fails the build; an added name only warns, so a
# routine upstream dependency addition does not break the build (versions are
# stripped so a plain bump is never flagged). Runs before the `sqlite-jdbc`
# swap below so it sees the pristine upstream set (the swap keeps the
# `sqlite-jdbc` name regardless). Regenerate the baseline by running the two
# find pipelines below and writing their `LC_ALL=C sort -u` output to the
# baseline file.
echo "Checking the dependency baseline."
lib_baseline="$script_dir/xmage-lib-baseline.txt"
[[ -f "$lib_baseline" ]] || fail "Missing dependency baseline: $lib_baseline."
lib_current="$work_dir/lib-current.txt"
{
  find "$client_src/lib" -maxdepth 1 -name '*.jar' -exec basename {} \; |
    sed -E 's/-[0-9].*$//; s/\.jar$//' | sed 's/^/client /'
  find "$server_src/lib" -maxdepth 1 -name '*.jar' -exec basename {} \; |
    sed -E 's/-[0-9].*$//; s/\.jar$//' | sed 's/^/server /'
} | LC_ALL=C sort -u >"$lib_current"
lib_added="$(LC_ALL=C comm -13 "$lib_baseline" "$lib_current")"
lib_removed="$(LC_ALL=C comm -23 "$lib_baseline" "$lib_current")"
if [[ -n "$lib_added" ]]; then
  echo "::warning::XMage dependencies not in the baseline (a routine addition? Update '$lib_baseline'):" >&2
  printf '%s\n' "$lib_added" >&2
fi
if [[ -n "$lib_removed" ]]; then
  echo "XMage dependencies recorded in the baseline are now gone:" >&2
  printf '%s\n' "$lib_removed" >&2
  fail "A relied-on dependency was removed upstream; review it and update '$lib_baseline'."
fi

# Swap the outdated `sqlite-jdbc` for a current one with an `arm64` native
# library.
old_sqlite="$(find "$server_src/lib" -maxdepth 1 -name 'sqlite-jdbc-*.jar' | head -1)"
[[ -n "$old_sqlite" ]] ||
  fail "Expected an sqlite-jdbc jar in 'mage-server/lib'; upstream layout changed."
echo "Replacing '$(basename "$old_sqlite")' with sqlite-jdbc '$SQLITE_JDBC_VERSION' (arm64 native)."
rm -f "$old_sqlite"
curl -fSL "$SQLITE_JDBC_URL" -o "$server_src/lib/sqlite-jdbc-$SQLITE_JDBC_VERSION.jar"

# Tame the "What's new" page. The bundled runtime has no JavaFX, so the patch
# makes `MageFrame` skip constructing the JavaFX-backed dialog entirely
# (avoiding a noisy caught initialization failure) and opens the page in the
# system browser only on an explicit request (the "Show what's new" button),
# not the automatic check on every launch. `MageFrame` lives in the client jar;
# since that jar is not fat, the recompile classpath is the whole client
# `lib/`.
# Upstream's source is Java 8, but `--release 8` is obsolete on the bundled JDK
# 25 (it warns, and a future JDK will drop it) while `--release 25` would
# needlessly target newer bytecode than the Java 8 classes this recompiled file
# sits beside; 17 is the floor: the lowest current LTS the JDK 25 toolchain
# accepts without the obsolescence warning. The patch also drops an unused
# `org.junit` import so the source compiles without the test dependency, which
# the distribution does not ship.
echo "Patching the What's new page."
apply_patches "$RAW_BASE" "$ref" "$script_dir/patches/xmage" 17 \
  "$client_src/lib/*" "$javac_bin" "$jar_bin" "$work_dir" \
  "Mage.Client/src/main/java/mage/client/MageFrame.java:$client_jar"

echo "Generating icon."
icon_src="$work_dir/label-xmage.png"
unzip -o -j "$client_jar" label-xmage.png -d "$work_dir" >/dev/null
[[ -f "$icon_src" ]] || fail 'XMage wordmark (label-xmage.png) not found in the client jar.'
icns="$work_dir/XMage.icns"
make_icon "$icon_src" "$icns"

# The bare names are the resource directories copied into each bundle's
# payload; the `:policy` lists tell the seeding script how to refresh each on
# an upgrade (see `write_seeding_script`). The client merges everything: its
# `plugins` holds the card image cache, so it cannot be replaced, and its lone
# plugin jar has a stable name (the client loads every jar there, so a renamed
# one would otherwise linger beside the new). The server replaces its
# version-stamped `plugins` and preserves its edited `config/config.xml`. Its
# `extensions` directory (a drop-in for user-installed card sets) is
# deliberately not seeded: the server creates it on startup, and leaving it
# unlisted keeps any installed extension across upgrades, the way runtime data
# under `db/` is kept.
client_items=(backgrounds config plugins sample-decks)
server_items=(config plugins server.msg.txt)
client_seed=(backgrounds:m config:m plugins:m sample-decks:m)
server_seed=(config:c plugins:r server.msg.txt:m)

client_app="$(package_component XMage "$client_src" "$client_jar" \
  mage.client.MageFrame "$CLIENT_HEAP" "$BUNDLE_ID.client" \
  "Open-source Magic: The Gathering client" "${client_items[@]}")"
server_app="$(package_component "XMage Server" "$server_src" "$server_jar" \
  mage.server.Main "$SERVER_HEAP" "$BUNDLE_ID.server" \
  "Open-source Magic: The Gathering server" "${server_items[@]}")"

echo "Wrapping launchers."
rename_launcher "$client_app" XMage
# Give the client launcher a Dock name and icon. The wrapper execs the `-bin`
# launcher, so without these the Dock and app switcher show the raw `XMage-bin`
# process with no icon.
{
  printf 'java-options=-Xdock:name=XMage\n'
  # `$APPDIR` is a jpackage runtime token, substituted by the native launcher.
  # shellcheck disable=SC2016
  printf 'java-options=-Xdock:icon=$APPDIR/../Resources/XMage.icns\n'
} >>"$client_app/Contents/app/XMage-bin.cfg"
write_seeding_script "$client_app/Contents/MacOS/XMage" XMage XMage-bin \
  "${client_seed[@]}"

# The server is headless and logs to its console, so it is wrapped to run
# inside a Terminal window where the log is visible and it can be stopped. The
# bundle's own launcher (what Finder starts) opens Terminal on the seeding run
# script, which seeds the working directory and then execs the server.
server_macos="$server_app/Contents/MacOS"
rename_launcher "$server_app" "XMage Server"
# Two server-only `java-options`. First, keep the headless JVM out of the Dock
# and app switcher (its Terminal window is the UI; it is started via the run
# script, not as the bundle, so it would otherwise appear there as a generic
# process). Second, grant native access so the bundled `sqlite-jdbc`'s
# `System::load` does not warn, and keeps working once a future JDK blocks
# restricted native access by default.
{
  printf 'java-options=-Dapple.awt.UIElement=true\n'
  printf 'java-options=--enable-native-access=ALL-UNNAMED\n'
} >>"$server_app/Contents/app/XMage Server-bin.cfg"
write_seeding_script "$server_macos/xmage-server-run" "XMage Server" \
  "XMage Server-bin" "${server_seed[@]}"
cat >"$server_macos/XMage Server" <<'LAUNCH'
#!/bin/sh

here="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/open -a Terminal "$here/xmage-server-run"
LAUNCH
chmod +x "$server_macos/XMage Server"

# Confirm jpackage embedded the runtime in each bundle before shipping.
assert_bundled_runtime "$client_app"
assert_bundled_runtime "$server_app"

echo "Ad-hoc signing bundles."
adhoc_sign_deep "$client_app"
adhoc_sign_deep "$server_app"

# Smoke-test the signed server headlessly by running its seeding script (the
# step the Terminal launcher would run) with `$HOME` redirected to a throwaway
# directory, then connect a headless client to it. Reaching the listening line
# confirms what nothing else in the build exercises: the bundled runtime
# starts, the seeded working directory is found, the swapped `sqlite-jdbc`
# loads its `arm64` native (the `user_stats` database is opened just before
# this line), the server plugins load, and the port binds. The client
# connection then confirms the one thing the server alone cannot: that the
# bundled JDK's `--add-opens` still lets the JBoss Remoting serialization work
# end to end, so a client can connect.
echo "Smoke-testing the server (headless startup and a client connection)."
smoke_home="$work_dir/smoke-home"
smoke_log="$work_dir/server-smoke.log"
mkdir -p "$smoke_home"
HOME="$smoke_home" "$server_macos/xmage-server-run" >"$smoke_log" 2>&1 &
smoke_pid=$!
i=0
until grep -q 'Started MAGE server' "$smoke_log" 2>/dev/null; do
  kill -0 "$smoke_pid" 2>/dev/null || {
    cat "$smoke_log" >&2
    fail 'Server exited before reaching its listening state.'
  }
  i=$((i + 1))
  if [[ "$i" -ge 180 ]]; then
    cat "$smoke_log" >&2
    fail 'Server smoke test timed out.'
  fi
  sleep 1
done

# Connect a tiny headless client, compiled against the same client `lib/` and
# run with the same `--add-opens` the bundles ship, to the running server. This
# is the only check that exercises the client-server serialization path, so it
# catches an upstream change that would need a different opens set (the client
# proper is not run here, as it needs a display, but it shares this stack).
echo "Connecting a headless client to the server."
cat >"$work_dir/ConnectCheck.java" <<'JAVA'
import mage.remote.Connection;
import mage.remote.SessionImpl;
import mage.interfaces.MageClient;
import mage.interfaces.callback.ClientCallback;
import mage.utils.MageVersion;

public class ConnectCheck {
  public static void main(String[] args) throws Exception {
    MageVersion version = new MageVersion(
      MageVersion.MAGE_VERSION_MAJOR, MageVersion.MAGE_VERSION_MINOR,
      MageVersion.MAGE_VERSION_RELEASE, MageVersion.MAGE_VERSION_RELEASE_INFO,
      ConnectCheck.class);
    MageClient client = new MageClient() {
      public MageVersion getVersion() { return version; }
      public void connected(String s) {}
      public void disconnected(boolean a, boolean b) {}
      public void showMessage(String s) {}
      public void showError(String s) {}
      public void onNewConnection() {}
      public void onCallback(ClientCallback cb) {}
    };
    SessionImpl session = new SessionImpl(client);
    Connection con = new Connection();
    con.setHost("localhost");
    con.setPort(args.length > 0 ? Integer.parseInt(args[0]) : 17171);
    con.setUsername("smoke-check");
    con.setUserIdStr("smoke-check:build:build:");
    con.setProxyType(Connection.ProxyType.NONE);
    boolean ok = session.connectStart(con);
    Thread.sleep(2000);
    boolean connected = session.isConnected();
    session.connectStop(false, false);
    if (ok && connected) {
      System.out.println("CONNECT_OK");
      System.exit(0);
    }
    System.out.println("CONNECT_FAIL ok=" + ok + " connected=" + connected
      + " lastError=[" + session.getLastError() + "]");
    System.exit(1);
  }
}
JAVA
connect_out="$work_dir/connectcheck"
mkdir -p "$connect_out"
"$javac_bin" -cp "$client_src/lib/*" -d "$connect_out" "$work_dir/ConnectCheck.java"
connect_log="$work_dir/connect-check.log"
# Dial the port the server actually binds (read from its configuration), so an
# upstream default-port change does not turn this into a misleading connection
# failure.
server_port="$(grep -oE 'port="[0-9]+"' "$server_src/config/config.xml" |
  grep -oE '[0-9]+' | head -1)" || true
if ! (cd "$work_dir" && HOME="$smoke_home" "$java_bin" "$XMAGE_ADD_OPENS" \
  -Djava.net.preferIPv4Stack=true -cp "$connect_out:$client_src/lib/*" \
  ConnectCheck "${server_port:-17171}") \
  >"$connect_log" 2>&1; then
  cat "$connect_log" "$smoke_log" >&2
  fail 'Headless client could not connect to the server.'
fi

# The server runs until killed; `wait` reaps it here so the shell does not
# print an asynchronous job-control notice for the signal.
kill -9 "$smoke_pid" 2>/dev/null || true
wait "$smoke_pid" 2>/dev/null || true
echo "Smoke test passed."

dmg="$out_dir/XMage-$version-arm64.dmg"
sha="$(make_dmg XMage "$dmg" "$client_app" "$server_app")"
echo "Built '$dmg'."
echo "channel=${channel:-n/a} version=$version"
echo "sha256=$sha"
