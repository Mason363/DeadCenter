#!/bin/bash
# Builds a signed, notarized Dead Center release into dist/.
#
#   Scripts/release.sh <version> [--build <number>] [--skip-notarize]
#
#   <version>        Marketing version, e.g. 1.2.0
#   --build N        CFBundleVersion. Defaults to major*10000 + minor*100 + patch, which always grows
#                    with the version (Sparkle compares this number).
#   --skip-notarize  Everything except notarizing and stapling, for a local dry run.
#
# Produces dist/DeadCenter-<version>.dmg, dist/appcast.xml and the browser extension packages.
# Upload all of them to the GitHub release tagged v<version>; the app's feed URL is
# https://github.com/Mason363/DeadCenter/releases/latest/download/appcast.xml
#
# One-time setup: a "Developer ID Application" certificate for team 8GFSXN32MA in the login keychain,
# the Sparkle signing key (Sparkle's generate_keys), and a notarytool keychain profile named DeadCenter.

set -euo pipefail

TEAM_ID="8GFSXN32MA"
IDENTITY="Developer ID Application"
NOTARY_PROFILE="DeadCenter"
REPO_URL="https://github.com/Mason363/DeadCenter"
APP_NAME="Dead Center"
VOLUME_NAME="Dead Center"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/release"
DIST="$ROOT/dist"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# MARK: Arguments

VERSION=""
BUILD=""
NOTARIZE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) NOTARIZE=0; shift ;;
    --build) BUILD="${2:?--build needs a number}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) fail "unknown option $1" ;;
    *) [[ -z "$VERSION" ]] || fail "unexpected argument $1"; VERSION="$1"; shift ;;
  esac
done
[[ -n "$VERSION" ]] || fail "usage: Scripts/release.sh <version> [--build <number>] [--skip-notarize]"
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] || fail "version must look like 1.2 or 1.2.3, got '$VERSION'"
if [[ -z "$BUILD" ]]; then
  BUILD=$(( 10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[4]:-0} ))
fi
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "build number must be an integer, got '$BUILD'"

# MARK: Preflight

say "Preflight"
for tool in xcodegen xcodebuild codesign hdiutil ditto; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
security find-identity -v -p codesigning | grep -q "$IDENTITY: .*($TEAM_ID)" \
  || fail "no '$IDENTITY' certificate for team $TEAM_ID in your keychain"
if (( NOTARIZE )); then
  if ! notary_check="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
    grep -qi "keychain\|profile" <<<"$notary_check" || fail "notarytool couldn't reach Apple: $notary_check"
    cat >&2 <<EOF

No notarytool credentials named "$NOTARY_PROFILE". Create them once (use an app-specific password
from https://account.apple.com):

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID email> --team-id $TEAM_ID

Or run with --skip-notarize for a local build.
EOF
    exit 1
  fi
fi
echo "Dead Center $VERSION ($BUILD)"

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"
ARCHIVE="$WORK/DeadCenter.xcarchive"
EXPORT="$WORK/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$DIST/DeadCenter-$VERSION.dmg"

# MARK: Build

say "Generating project"
(cd "$ROOT" && xcodegen generate --quiet)

say "Archiving (universal)"
xcodebuild archive \
  -project "$ROOT/DeadCenter.xcodeproj" \
  -scheme DeadCenter \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$WORK/DerivedData" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  -quiet || fail "archive failed"

say "Exporting with Developer ID"
cat > "$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -quiet || fail "export failed"
[[ -d "$APP" ]] || fail "export produced no $APP_NAME.app"

# MARK: Signing

say "Signing Sparkle's helpers"
# Inside out: every nested executable needs our Developer ID, the hardened runtime and a secure
# timestamp, or notarization rejects the whole app. Re-signing them explicitly doesn't depend on
# what Xcode's export happened to do.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  SPARKLE_V="$SPARKLE/Versions/B"
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
  [[ -d "$SPARKLE_V/XPCServices/Installer.xpc" ]] && sign "$SPARKLE_V/XPCServices/Installer.xpc"
  [[ -d "$SPARKLE_V/XPCServices/Downloader.xpc" ]] && sign --preserve-metadata=entitlements "$SPARKLE_V/XPCServices/Downloader.xpc"
  sign "$SPARKLE_V/Autoupdate"
  sign "$SPARKLE_V/Updater.app"
  sign "$SPARKLE"
  # The framework changed, so the app's seal must be renewed (keeping its entitlements).
  sign --preserve-metadata=entitlements,requirements,flags "$APP"
fi

say "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
# Notarization wants every Mach-O signed with our Developer ID and a secure timestamp, and every
# executable (not libraries, which run under their host's runtime) with the hardened runtime.
bad=0
while IFS= read -r -d '' file; do
  kind="$(file -b "$file")"
  [[ "$kind" == *Mach-O* ]] || continue
  info="$(codesign -dvvv "$file" 2>&1 || true)"
  problem=""
  grep -q "Authority=$IDENTITY" <<<"$info" || problem="not signed with $IDENTITY"
  grep -q "Timestamp=" <<<"$info" || problem="${problem:+$problem, }no secure timestamp"
  if [[ "$kind" == *executable* ]] && ! grep -Eq "flags=0x[0-9a-f]*\(.*runtime" <<<"$info"; then
    problem="${problem:+$problem, }no hardened runtime"
  fi
  if [[ -n "$problem" ]]; then
    echo "  ${file#"$APP/"}: $problem"
    bad=1
  fi
done < <(find "$APP" -type f -perm -u+x -print0)
(( bad == 0 )) || fail "some binaries aren't ready for notarization"
echo "  all code signed with Developer ID and a secure timestamp; executables use the hardened runtime"

archs="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "  architectures: $archs"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "expected a universal binary, got: $archs"

notarize() {
  local target="$1" upload="$1"
  if [[ -d "$target" ]]; then
    upload="$WORK/$(basename "$target" .app)-notarize.zip"
    ditto -c -k --keepParent "$target" "$upload"
  fi
  xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m \
    | tee "$WORK/notary.log"
  grep -q "status: Accepted" "$WORK/notary.log" || fail "notarization of $(basename "$target") was not accepted (see notarytool log)"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

if (( NOTARIZE )); then
  say "Notarizing the app"
  notarize "$APP"
else
  say "Skipping notarization (--skip-notarize)"
fi

# MARK: Disk image

say "Building the disk image"
STAGE="$WORK/dmg"
RW_DMG="$WORK/rw.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

# The volume wears the app icon (copied in after mounting; -srcfolder drops it).
ICONSET="$WORK/VolumeIcon.iconset"
APPICON="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  cp "$APPICON/icon_$size.png" "$ICONSET/icon_${size}x${size}.png"
  cp "$APPICON/icon_$((size * 2)).png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$WORK/VolumeIcon.icns"

rm -f "$RW_DMG" "$DMG"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[[ -d "$MOUNT" ]] || fail "couldn't mount the disk image"

# Window layout: app on the left, Applications on the right. Needs Automation access to Finder;
# without it the image is still fine, just with Finder's default layout.
if ! osascript - "$(basename "$MOUNT")" "$APP_NAME.app" >/dev/null 2>&1 <<'APPLESCRIPT'
on run {volumeName, appName}
  tell application "Finder"
    tell disk volumeName
      open
      set win to container window
      set current view of win to icon view
      set toolbar visible of win to false
      set statusbar visible of win to false
      try
        set pathbar visible of win to false
      end try
      set bounds of win to {200, 120, 760, 480}
      set opts to icon view options of win
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 13
      set position of item appName of win to {150, 150}
      set position of item "Applications" of win to {410, 150}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "  (Finder layout skipped: grant Automation access to Finder to get the arranged window)"
fi
cp "$WORK/VolumeIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" || echo "  (couldn't set the volume icon flag)"
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach -quiet "$MOUNT" || hdiutil detach -force -quiet "$MOUNT"
hdiutil convert -quiet "$RW_DMG" -format ULFO -o "$DMG"
rm -f "$RW_DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( NOTARIZE )); then
  say "Notarizing the disk image"
  notarize "$DMG"
fi

# MARK: Appcast

say "Generating the appcast"
SPARKLE_BIN="$(find "$WORK/DerivedData/SourcePackages/artifacts" -type d -path "*Sparkle/bin" -print -quit 2>/dev/null || true)"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle's generate_appcast wasn't found in the build's packages"
APPCAST_DIR="$WORK/appcast"
mkdir -p "$APPCAST_DIR"
# Start from the published feed so earlier versions stay listed.
curl -fsSL "$REPO_URL/releases/latest/download/appcast.xml" -o "$APPCAST_DIR/appcast.xml" 2>/dev/null \
  || rm -f "$APPCAST_DIR/appcast.xml"
cp "$DMG" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --link "$REPO_URL" \
  "$APPCAST_DIR"
cp "$APPCAST_DIR/appcast.xml" "$DIST/appcast.xml"
echo "  EdDSA signature: $("$SPARKLE_BIN/sign_update" "$DMG" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"

# MARK: Browser extensions

if [[ -x "$ROOT/Scripts/build-extensions.sh" ]]; then
  say "Packaging browser extensions"
  "$ROOT/Scripts/build-extensions.sh"
fi

say "Done"
ls -lh "$DIST" | sed 1d
if (( ! NOTARIZE )); then
  echo
  echo "Not notarized: Gatekeeper will refuse this build on other Macs. Drop --skip-notarize to ship."
fi
