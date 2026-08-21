#!/bin/zsh
set -euo pipefail

APP_NAME="Capsomnia"
LABEL="com.github.fuji-mak.capsomnia"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
LEGACY_INSTALL_DIR="$HOME/Library/Application Support/$APP_NAME"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
HELPER_PATH="/Library/PrivilegedHelperTools/capsomnia-pmset"
LEGACY_HELPER_PATH="/usr/local/sbin/capsomnia-pmset"
SUDOERS_PATH="/etc/sudoers.d/capsomnia"
CURRENT_USER="$(id -un)"

if [[ "$CURRENT_USER" == *[!A-Za-z0-9._-]* ]]; then
  echo "Unsupported macOS short user name for sudoers: $CURRENT_USER" >&2
  exit 64
fi

build_tmp="$(mktemp -d)"
sudoers_tmp=""
cleanup() {
  [[ -n "$sudoers_tmp" ]] && /bin/rm -f "$sudoers_tmp"
  [[ -n "$build_tmp" ]] && /bin/rm -rf "$build_tmp"
}
trap cleanup EXIT

mkdir -p "$HOME/Applications" "$LOG_DIR" "$HOME/Library/LaunchAgents"

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
/usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true

cd "$ROOT_DIR"
BUILT_APP="$("$ROOT_DIR/scripts/build-app.sh" "$build_tmp/$APP_NAME.app")"
# Pinned the instant the build finishes, and re-checked just before root reads it. Staging
# under root closes the window between validation and install; it cannot close the window
# between the compiler writing this file and root copying it, because the build has to run
# as this user. This shrinks that window to the gap between two adjacent commands and makes
# a swap inside it fatal instead of silent. It is a mitigation, not a boundary — the real
# boundary is a signed installer package whose payload is authenticated before it is
# trusted, which is tracked as follow-up work, not solved here.
HELPER_BUILD_SHA="$(/usr/bin/shasum -a 256 ".build/release/capsomnia-pmset" | /usr/bin/awk '{print $1}')"
/bin/rm -rf "$APP_BUNDLE"
/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"
/bin/rm -rf "$LEGACY_INSTALL_DIR"

sudo /bin/mkdir -p "$(dirname "$HELPER_PATH")" "$(dirname "$SUDOERS_PATH")"
sudo /usr/sbin/chown root:wheel "$(dirname "$HELPER_PATH")" "$(dirname "$SUDOERS_PATH")"
sudo /bin/chmod 0755 "$(dirname "$HELPER_PATH")" "$(dirname "$SUDOERS_PATH")"

# Every ancestor of the helper must be root-owned and not writable by this user, or the
# sudoers rule — which authorises BY PATHNAME — can be pointed at someone else's binary
# through a replaced directory. Checked rather than forced: silently chmod'ing system
# directories to make an install succeed is how you paper over a real problem.
check_dir="$(dirname "$HELPER_PATH")"
while :; do
  owner="$(/usr/bin/stat -f '%Su' "$check_dir")"
  perms="$(/usr/bin/stat -f '%Sp' "$check_dir")"
  if [[ "$owner" != "root" ]]; then
    echo "Refusing to install: $check_dir is owned by $owner, not root." >&2
    exit 76
  fi
  case "$perms" in
    ?????w*|????????w*) echo "Refusing to install: $check_dir is group- or world-writable ($perms)." >&2; exit 76 ;;
  esac
  [[ "$check_dir" == "/" ]] && break
  check_dir="$(dirname "$check_dir")"
done

# STAGE UNDER ROOT BEFORE VALIDATING OR TRUSTING ANYTHING.
#
# The build output lives in a directory this user can write. Between `swift build` and
# `sudo install`, any process running as this user — a malicious npm/pip postinstall, a
# compromised app — can replace `.build/release/capsomnia-pmset` and have ITS binary
# installed root-owned, then invoked as root with no password by the sudoers rule below.
# The same holds for the sudoers file itself: created and `visudo`-validated as the user,
# it can be swapped for `NOPASSWD: ALL` in the window before root copies it. `mktemp`
# stops other users, not other processes sharing this UID.
#
# Both are closed the same way: copy into a root-owned 0700 directory first, then validate
# and install from THERE, where this user can no longer reach it.
STAGE_DIR="$(sudo /usr/bin/mktemp -d /var/root/capsomnia-install.XXXXXX)"
sudo /bin/chmod 0700 "$STAGE_DIR"
stage_cleanup() { sudo /bin/rm -rf "$STAGE_DIR" 2>/dev/null || true; }
trap 'stage_cleanup; cleanup' EXIT

if [[ "$(/usr/bin/shasum -a 256 ".build/release/capsomnia-pmset" | /usr/bin/awk '{print $1}')" != "$HELPER_BUILD_SHA" ]]; then
  echo "Refusing to install: the helper binary changed after it was built." >&2
  exit 76
fi
sudo /usr/bin/install -o root -g wheel -m 0755 ".build/release/capsomnia-pmset" "$STAGE_DIR/capsomnia-pmset"
if [[ "$(sudo /usr/bin/shasum -a 256 "$STAGE_DIR/capsomnia-pmset" | /usr/bin/awk '{print $1}')" != "$HELPER_BUILD_SHA" ]]; then
  echo "Refusing to install: the staged helper does not match what was built." >&2
  exit 76
fi

sudoers_tmp="$STAGE_DIR/sudoers"
# The digest binds the rule to THIS binary's contents, so authorising by pathname is no
# longer authorising whatever later occupies that pathname. Computed from the staged,
# root-owned copy — computing it from the user-writable build output would just move the
# race. Every legitimate helper change must go through this script so the digest follows.
HELPER_SHA="$(sudo /usr/bin/shasum -a 256 "$STAGE_DIR/capsomnia-pmset" | /usr/bin/awk '{print $1}')"
sudo /usr/bin/tee "$sudoers_tmp" > /dev/null <<EOF
# Allow Capsomnia to toggle only its fixed pmset helper, and only this exact binary.
$CURRENT_USER ALL=(root) NOPASSWD: sha256:$HELPER_SHA $HELPER_PATH on, sha256:$HELPER_SHA $HELPER_PATH off, sha256:$HELPER_SHA $HELPER_PATH display-sleep
EOF
sudo /bin/chmod 0440 "$sudoers_tmp"
sudo /usr/sbin/chown root:wheel "$sudoers_tmp"

sudo /usr/sbin/visudo -cf "$sudoers_tmp"
sudo /usr/bin/install -o root -g wheel -m 0755 "$STAGE_DIR/capsomnia-pmset" "$HELPER_PATH"
sudo /bin/rm -f "$LEGACY_HELPER_PATH"
sudo /usr/bin/install -o root -g wheel -m 0440 "$sudoers_tmp" "$SUDOERS_PATH"

cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>

  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$LABEL</string>
  </array>

  <key>ProgramArguments</key>
  <array>
    <string>$APP_BUNDLE/Contents/MacOS/$APP_NAME</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>$LOG_DIR/stdout.log</string>

  <key>StandardErrorPath</key>
  <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
EOF

# The app is adhoc/linker-signed, so every rebuild changes its code identity. macOS binds
# ~/Library/Preferences/$LABEL.plist to the identity that created it via the `com.apple.macl`
# xattr; after an identity change cfprefsd silently stops being able to write that file. The
# app keeps accepting settings, keeps logging them, keeps acting on them for the life of the
# process — and loses every one of them at the next launch. Measured 2026-08-21: the user's
# mode change was accepted and applied at 12:05:00Z while the on-disk file still held a value
# from 14:56 the previous day, and three restarts in a row reverted his choice.
# Clearing the xattrs here costs nothing and stops that from returning on the next rebuild.
PREFS_PLIST="$HOME/Library/Preferences/$LABEL.plist"
if [[ -f "$PREFS_PLIST" ]]; then
  # Only the attribute that is actually in the way. `xattr -c` also removed quarantine and
  # any future provenance metadata, which was never the point.
  /usr/bin/xattr -d com.apple.macl "$PREFS_PLIST" 2>/dev/null || true
fi

launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed $APP_NAME."
